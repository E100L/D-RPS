--[[ D-RPS — server/interactions.lua
     Interaktions-Graph: fuehrt pro Spielerpaar ein gleitendes Fenster (Naehe-Dauer,
     letzter Chat/Voice/Schaden). Beantwortet server-autoritativ "gab es vorher Kontakt?".
     Kosten O(n²) Distanzpruefungen bei 2 Hz — bei 48 Spielern trivial. ]]

Interactions = {}

-- graph[key] = Paar-Eintrag; key = "min:max" der beiden src (ungerichtet)
local graph = {}

local function pairKey(a, b)
    if a < b then return a .. ':' .. b else return b .. ':' .. a end
end

local function ensurePair(a, b, now)
    local k = pairKey(a, b)
    local e = graph[k]
    if not e then
        e = { a = math.min(a, b), b = math.max(a, b),
              proximityMs = 0, lastProximity = nil,
              lastChat = nil, lastVoice = nil,
              lastDamage = nil, lastDamageFrom = nil,
              sharedVehicle = nil, firstSeen = now }
        graph[k] = e
    end
    return e
end

-- == Positions-Helfer ==

local function livePos(src)
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 and DoesEntityExist(ped) then return GetEntityCoords(ped) end
    return nil
end

-- == Externe Signale: Chat, Voice, Damage ==

--- Chat -> allen Spielern in Reichweite als Kontakt anrechnen.
function Interactions.RecordChat(src, text)
    local now = GetGameTimer()
    local p = livePos(src); if not p then return end
    for _, sp in ipairs(GetPlayers()) do
        local other = tonumber(sp)
        if other ~= src then
            local op = livePos(other)
            if op and #(p - op) <= Config.CommsRangeMeters then
                local e = ensurePair(src, other, now)
                e.lastChat = now
                if text then e.lastChatText = text end
            end
        end
    end
end

--- Analog fuer Sprache (vom Voice-Adapter gespeist).
function Interactions.RecordVoice(src)
    local now = GetGameTimer()
    local p = livePos(src); if not p then return end
    for _, sp in ipairs(GetPlayers()) do
        local other = tonumber(sp)
        if other ~= src then
            local op = livePos(other)
            if op and #(p - op) <= Config.CommsRangeMeters then
                ensurePair(src, other, now).lastVoice = now
            end
        end
    end
end

--- Schaden zwischen zwei Spielern (aus events.lua, richtungsbehaftet).
function Interactions.RecordDamage(shooter, victim)
    if not shooter or not victim or shooter == victim then return end
    local e = ensurePair(shooter, victim, GetGameTimer())
    e.lastDamage = GetGameTimer()
    e.lastDamageFrom = shooter
end

-- == Abfrage-API fuer die Detektoren ==

--- Roheintrag eines Paares (oder nil).
function Interactions.Between(a, b) return graph[pairKey(a, b)] end

--- Hatten A und B in den letzten `withinMs` irgendeinen Kontakt? Kernfrage fuer RDM.
function Interactions.HadContact(a, b, withinMs)
    local e = graph[pairKey(a, b)]
    if not e then return false end
    local now, w = GetGameTimer(), withinMs
    local function fresh(t) return t and (now - t) <= w end
    -- Echter Kontakt = Comms/gemeinsames Fahrzeug/laengere Naehe/Schlagabtausch. Blosse Sichtweite zaehlt NICHT (sonst Nah-RDM unsichtbar).
    return fresh(e.lastChat) or fresh(e.lastVoice) or fresh(e.sharedVehicle)
        or (e.proximityMs or 0) >= 3000    -- ≥3s kumuliert = echter Kontakt
        or fresh(e.lastDamage)             -- vorheriger Schlagabtausch
end

--- Wie viele Sekunden waren A und B insgesamt in Naehe (im Fenster)?
function Interactions.ProximitySeconds(a, b)
    local e = graph[pairKey(a, b)]
    return e and (e.proximityMs / 1000.0) or 0.0
end

-- == Update-Loop: Naehe messen + alte Eintraege verwerfen ==

CreateThread(function()
    local windowMs = Config.InteractionWindowMinutes * 60 * 1000
    local lastTick = GetGameTimer()

    while true do
        Wait(Config.InteractionUpdateMs)
        if Recording then
            local now = GetGameTimer()
            local dt  = now - lastTick
            lastTick  = now

            -- Positionen einmal einsammeln
            local players = GetPlayers()
            local pos = {}
            for _, sp in ipairs(players) do
                local src = tonumber(sp)
                pos[src] = livePos(src)
            end

            -- Paare pruefen (O(n²), nur Distanz)
            for i = 1, #players do
                local a = tonumber(players[i])
                local pa = pos[a]
                if pa then
                    for j = i + 1, #players do
                        local b = tonumber(players[j])
                        local pb = pos[b]
                        if pb and #(pa - pb) <= Config.ProximityMeters then
                            local e = ensurePair(a, b, now)
                            e.proximityMs = e.proximityMs + dt
                            e.lastProximity = now
                            -- gemeinsames Fahrzeug?
                            local va = GetVehiclePedIsIn(GetPlayerPed(a), false)
                            if va ~= 0 and va == GetVehiclePedIsIn(GetPlayerPed(b), false) then
                                e.sharedVehicle = now
                            end
                        end
                    end
                end
            end

            -- Aufraeumen: Eintraege, deren juengstes Signal aus dem Fenster faellt
            for k, e in pairs(graph) do
                local newest = math.max(e.lastProximity or 0, e.lastChat or 0,
                                        e.lastVoice or 0, e.lastDamage or 0, e.sharedVehicle or 0)
                if (now - newest) > windowMs then graph[k] = nil end
            end
        end
    end
end)

return Interactions
