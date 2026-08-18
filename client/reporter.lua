--[[ ===========================================================================
    D-RPS — Dollar Replay System
    client/reporter.lua

    Client-Reporter (Fidelity-Layer, §3.3): meldet das Aussehen des eigenen Peds
    (Model, Kleidung, Props) fuer die Optik des Replays. Client-gemeldet, also
    spoofbar (§4.1), fuer die Regelbruch-Erkennung irrelevant. Nur bei Aenderung senden.
=========================================================================== ]]

local lastSig = nil

--- Fingerabdruck fuer den Aenderungsvergleich. Bewusst OHNE json.encode
--- (kann werfen); eine Zeichenkette aus den Werten selbst nicht.
local function sigOf(a)
    local t = { tostring(a.model) }
    local function add(list, n, fmt)
        for i = 1, n do t[#t + 1] = (fmt):format(list and list[i] or 0) end
    end
    add(a.comp, 36, '%d')
    add(a.prop, 16, '%d')
    add(a.head, 9,  '%.4f')
    add(a.face, 20, '%.4f')
    add(a.over, 65, '%.3f')
    add(a.hair, 2,  '%d')
    t[#t + 1] = tostring(a.eyes or 0)
    -- Skin-Tabelle mit einbeziehen (sonst kein Wechsel aus dem Charaktermenue).
    -- Schluessel sortiert, da pairs keine feste Reihenfolge hat.
    if type(a.skin) == 'table' then
        local keys = {}
        for k in pairs(a.skin) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            t[#t + 1] = keys[i] .. '=' .. tostring(a.skin[keys[i]])
        end
    end
    return table.concat(t, '|')
end

--- Elternmischung eines Freemode-Gesichts, robust gegen beide Rueckgabeformen
--- des Natives. Rueckgabe: flaches 9er-Array (3 Formeltern, 3 Hauteltern, 3
--- Mischanteile) oder nil bei echtem Nicht-Freemode-Ped.
local function captureHead(ped)
    local ok, r1, r2, r3, r4, r5, r6, r7, r8, r9 = pcall(GetPedHeadBlendData, ped)
    if not ok then return nil end

    -- Form 1: Tabelle mit benannten Feldern (Namen wechseln je Build).
    if type(r1) == 'table' then
        local t = r1
        local sf = t.shapeFirst  or t.shapeFirstID
        if sf == nil then return nil end
        return {
            sf,                              t.shapeSecond or t.shapeSecondID or 0,
            t.shapeThird or t.shapeThirdID or 0,
            t.skinFirst  or t.skinFirstID  or 0, t.skinSecond or t.skinSecondID or 0,
            t.skinThird  or t.skinThirdID  or 0,
            t.shapeMix or 0.5, t.skinMix or 0.5, t.thirdMix or 0.0,
        }
    end

    -- Form 2: neun einzelne Rueckgabewerte (Fall auf dem Zielserver).
    if type(r1) == 'number' then
        return {
            r1, r2 or 0, r3 or 0,
            r4 or 0, r5 or 0, r6 or 0,
            (r7 or 0.5) + 0.0, (r8 or 0.5) + 0.0, (r9 or 0.0) + 0.0,
        }
    end

    return nil
end

--- Eine Kopf-Auflage build-unabhaengig auslesen. Native heisst je Build
--- GetPedHeadOverlay oder GetPedHeadOverlayData; vorhandenes waehlen und einen
--- etwaigen fuehrenden Wahrheitswert ueberspringen.
--- Rueckgabe: value, colourType, firstColour, secondColour, opacity.
local function readOverlay(ped, i)
    local fn = GetPedHeadOverlayData or GetPedHeadOverlay
    if type(fn) ~= 'function' then return 255, 0, 0, 0, 1.0 end
    local r = { pcall(fn, ped, i) }
    if r[1] ~= true then return 255, 0, 0, 0, 1.0 end   -- Aufruf fehlgeschlagen
    -- Fuehrender Wahrheitswert ist der Erfolgs-Bool; Nutzwerte dann eins spaeter.
    local o = (type(r[2]) == 'boolean') and 3 or 2
    return r[o], r[o + 1], r[o + 2], r[o + 3], r[o + 4]
end

--- Aussehen des eigenen Peds erfassen. Neben Kleidung (comp) und Accessoires
--- (prop) auch das Gesicht: Elternmischung (head), Gesichtszuege (face),
--- Auflagen (over) und Haarfarben — sonst sitzt "irgendein Charakter" im Auto.
--- Jeder Zugriff in pcall (Natives fehlen auf manchen Builds); Fehlendes fehlt.
local function capture()
    local ped = PlayerPedId()
    local a = { model = GetEntityModel(ped), comp = {}, prop = {} }

    -- FLACHE, 1-BASIERTE ARRAYS: 0-indizierte Lua-Tabellen ueberleben die
    -- Netzgrenze nicht (werden zur Abbildung). Server setzt das flache Array zusammen.
    for i = 0, 11 do
        local k = i * 3
        a.comp[k + 1] = GetPedDrawableVariation(ped, i)
        a.comp[k + 2] = GetPedTextureVariation(ped, i)
        a.comp[k + 3] = GetPedPaletteVariation(ped, i)
    end
    for i = 0, 7 do
        local k = i * 2
        a.prop[k + 1] = GetPedPropIndex(ped, i)
        a.prop[k + 2] = GetPedPropTextureIndex(ped, i)
    end

    -- Elternmischung: welche Eltern, Mischgrad, Hautton. captureHead bedient
    -- beide Build-Formen (Tabelle vs. Einzelwerte) und beide Feldnamen.
    a.head = captureHead(ped)

    -- Gesichtszuege: Nasenbreite, Wangenknochen, Kinn und so weiter.
    a.face = {}
    for i = 0, 19 do
        local okF, val = pcall(GetPedFaceFeature, ped, i)
        a.face[i + 1] = (okF and type(val) == 'number') and val or 0.0
    end

    -- Auflagen: Bart, Augenbrauen, Sommersprossen, Make-up, Alterung.
    -- readOverlay ueberspringt einen fuehrenden Erfolgs-Wahrheitswert (sonst
    -- saessen alle Werte um eine Stelle verschoben). 255 = keine Auflage.
    a.over = {}
    for i = 0, 12 do
        local k = i * 5
        local val, colType, col1, col2, opacity = readOverlay(ped, i)
        a.over[k + 1] = (type(val) == 'number') and val or 255
        a.over[k + 2] = (type(colType) == 'number') and colType or 0
        a.over[k + 3] = (type(col1) == 'number') and col1 or 0
        a.over[k + 4] = (type(col2) == 'number') and col2 or 0
        a.over[k + 5] = (type(opacity) == 'number') and opacity or 1.0
    end

    local okHc, hc = pcall(GetPedHairColor, ped)
    local okHh, hh = pcall(GetPedHairHighlightColor, ped)
    local okEc, ec = pcall(GetPedEyeColour, ped)
    a.hair = { okHc and hc or 0, okHh and hh or 0 }
    a.eyes = okEc and ec or 0

    -- Voll-Aussehen aus dem Charaktersystem (skinchanger), falls vorhanden:
    -- haelt alles exakt und ueberstimmt die unvollstaendigen Nativewerte.
    -- Fehlt es (Standalone), bleibt der Native-Weg oben der Rueckfall.
    local ok, skin = pcall(function()
        return exports['skinchanger'] and exports['skinchanger']:GetSkin() or nil
    end)
    if ok and type(skin) == 'table' and skin.sex ~= nil then
        a.skin = skin
    end

    return a
end

CreateThread(function()
    -- kurz warten, bis der Spieler-Ped/Charakter geladen ist
    Wait(5000)
    while true do
        local a = capture()
        local sig = sigOf(a)
        if sig ~= lastSig then
            lastSig = sig
            TriggerServerEvent('d-rps:reportAppearance', a)
        end
        Wait(5000)
    end
end)

-- Bei explizitem Skin-Wechsel (z.B. Kleidungsladen) sofort neu melden lassen —
-- andere Resources koennen dieses Event feuern.
RegisterNetEvent('d-rps:refreshAppearance', function()
    lastSig = nil
end)

-- ── Welt-Zustand: Uhrzeit + Wetter ─────────────────────────────────────────
-- Server kennt beides nicht; Client meldet es fuer die Szenen-Rekonstruktion (§11.1).
-- Wetter als TRANSITION (zwei Hashes + Blend), damit der geblendete Zustand rundtrippt.
CreateThread(function()
    Wait(8000)
    while true do
        local h, m, s = GetClockHours(), GetClockMinutes(), GetClockSeconds()
        local w1, w2, pct = GetWeatherTypeTransition()
        TriggerServerEvent('d-rps:reportWorld', {
            h = h, m = m, s = s,
            w1 = w1, w2 = w2, pct = pct,
        })
        Wait(10000)
    end
end)
