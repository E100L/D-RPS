--[[ D-RPS — server/detection.lua
     Detection-Layer: erzeugt aus Events + Interaktions-Graph Konfidenz-bewertete
     HINWEISE zur menschlichen Pruefung (Combat-Log/RDM/VDM/Spawn-Kill/NLR). Nie Auto-Bans. ]]

Detection = {}

local lastCombat  = {}    -- [src] = GetGameTimer() des letzten Schadens (gegeben/genommen)
local spawnedAt   = {}    -- [src] = GetGameTimer() des letzten Spawns/Joins
local deathInfo   = {}    -- [src] = { pos, t, hasLeft } fuer NLR
local lastWpnDmg  = {}    -- [src] = GetGameTimer() des letzten WAFFEN-Schadens (VDM-Abgrenzung)
local lastHealth  = {}    -- [src] = letzter Health-Wert (Health-Watcher fuer VDM)
local incidents   = {}    -- Ring der erzeugten Incidents
local nextId      = 1

-- Fahrzeug-Waffen-Hashes (signed->unsigned normalisiert)
local function gh(name) local h = GetHashKey(name); return h < 0 and h + 0x100000000 or h end
local WEAPON_RUN_OVER = gh('WEAPON_RUN_OVER_BY_VEHICLE')
local WEAPON_RAMMED   = gh('WEAPON_RAMMED_BY_VEHICLE')

-- == Incident-Erzeugung ==

local function nameOf(src)
    return src and (('%s[%s]'):format(GetPlayerName(src) or '?', src)) or '?'
end

local recentKeys = {}   -- Dedup: [type:shooter:victim] = GetGameTimer()

local function createIncident(itype, confidence, involved, data)
    if confidence < Config.DetectMinConfidence then return end

    -- Selbstschaden ist kein Regelbruch
    if involved.shooter and involved.victim and involved.shooter == involved.victim then return end

    -- Dedup: gleicher Typ + Beteiligte innerhalb 30s nur einmal (sonst Incident-Flut durch Schadens-Ticks)
    local key = ('%s:%s:%s'):format(itype, tostring(involved.shooter), tostring(involved.victim))
    local last = recentKeys[key]
    if last and (GetGameTimer() - last) < 30000 then return end
    recentKeys[key] = GetGameTimer()

    local inc = {
        id = nextId, type = itype, confidence = confidence,
        t = os.time(), gt = GetGameTimer(),
        involved = involved, data = data or {},
    }
    nextId = nextId + 1
    incidents[#incidents + 1] = inc
    if #incidents > 500 then table.remove(incidents, 1) end

    print(('^1[D-RPS INCIDENT #%d] %s (Konfidenz %.0f%%) — %s^0'):format(
        inc.id, itype:upper(), confidence * 100, data.summary or ''))

    -- Discord-Alert (optional)
    if Config.DiscordWebhook ~= '' then
        local col = confidence >= 0.8 and 15158332 or 15844367   -- rot / orange
        PerformHttpRequest(Config.DiscordWebhook, function() end, 'POST', json.encode({
            embeds = { {
                title = ('D-RPS: %s (Verdacht)'):format(itype:upper()),
                description = data.summary or '',
                color = col,
                fields = {
                    { name = 'Konfidenz', value = ('%.0f%%'):format(confidence * 100), inline = true },
                    { name = 'Zeit', value = os.date('%H:%M:%S', inc.t), inline = true },
                },
                footer = { text = ('Incident #%d — Hinweis zur Pruefung, kein Beweis'):format(inc.id) },
            } },
        }), { ['Content-Type'] = 'application/json' })
    end

    return inc
end

function Detection.Recent(n)
    n = n or 10
    local out = {}
    for i = math.max(1, #incidents - n + 1), #incidents do out[#out + 1] = incidents[i] end
    return out
end

-- == Kampf-/Spawn-/Death-Tracking ==

local function markCombat(src)
    if src then lastCombat[src] = GetGameTimer() end
end

--- VDM flaggen. Konfidenz aus Geschwindigkeit und fehlender Vorgeschichte.
function Detection.FlagVDM(shooter, victim, speed)
    if not Config.Detect.VDM or not shooter or not victim then return end
    if speed < Config.VdmMinSpeed then return end
    local contact = Interactions.HadContact(shooter, victim, Config.RdmLookbackMinutes * 60000)
    local conf = 0.55 + (contact and 0.0 or 0.25) + math.min(0.15, (speed - Config.VdmMinSpeed) / 100)
    createIncident('vdm', conf, { shooter = shooter, victim = victim }, {
        speed = speed, hadContact = contact,
        summary = ('%s faehrt %s an (%.0f km/h%s)'):format(
            nameOf(shooter), nameOf(victim), speed * 3.6,
            contact and ', mit Vorgeschichte' or ', OHNE Vorgeschichte'),
    })
end

-- == Health-Watcher: VDM ohne weaponDamageEvent ==
-- Anfahren erzeugt oft kein Waffen-Event: unerklaerter Health-Verlust + schnelles Fahrzeug nah = VDM.
CreateThread(function()
    while true do
        Wait(100)   -- 10 Hz — Anfahren ist ein kurzer Moment
        if Recording then
            for _, sp in ipairs(GetPlayers()) do
                local src = tonumber(sp)
                local ped = GetPlayerPed(src)
                if ped ~= 0 and DoesEntityExist(ped) then
                    local hp   = GetEntityHealth(ped)
                    local prev = lastHealth[src]
                    if prev and hp < prev - 3 then
                        local vpos = GetEntityCoords(ped)
                        local wpn  = lastWpnDmg[src]
                        local byWeapon = wpn and (GetGameTimer() - wpn) < 700

                        -- naechstes fremdes Fahrzeug samt Speed/Distanz ermitteln
                        local bestVeh, bestSpeed, bestDist, bestOwner = nil, 0, 9999, nil
                        for _, sp2 in ipairs(GetPlayers()) do
                            local other = tonumber(sp2)
                            if other ~= src then
                                local oveh = GetVehiclePedIsIn(GetPlayerPed(other), false)
                                if oveh ~= 0 then
                                    local d = #(GetEntityCoords(oveh) - vpos)
                                    if d < bestDist then
                                        bestDist = d; bestSpeed = GetEntitySpeed(oveh)
                                        bestVeh = oveh; bestOwner = other
                                    end
                                end
                            end
                        end

                        RPSDiag(('HEALTHLOSS victim=%s %d->%d byWeapon=%s | nearVeh owner=%s speed=%.1f dist=%.1f'):format(
                            src, prev, hp, tostring(byWeapon),
                            tostring(bestOwner), bestSpeed, bestDist))

                        -- VDM: unerklaerter Schaden + schnelles Fahrzeug nah
                        if not byWeapon and bestOwner and bestSpeed >= Config.VdmMinSpeed and bestDist < 10.0 then
                            Detection.FlagVDM(bestOwner, src, bestSpeed)
                        end
                    end
                    lastHealth[src] = hp
                end
            end
        end
    end
end)

AddEventHandler('D-RPS:internal:spawn', function(src) spawnedAt[src] = GetGameTimer() end)

-- == Detektor-Eingang: jedes Damage-Event ==

Events.OnEvent(function(ev)
    if ev.type ~= 'damage' then return end
    local shooter, victim = ev.shooter, ev.victim
    markCombat(shooter); markCombat(victim)

    if not victim then return end   -- ab hier nur Spieler-gegen-Spieler

    local now = GetGameTimer()
    lastWpnDmg[victim] = now   -- Waffenschaden -> grenzt VDM ab

    -- Todesort fuer NLR merken
    if ev.willKill and ev.victimPos then
        deathInfo[victim] = { pos = ev.victimPos, t = os.time(), hasLeft = false }
    end

    -- Fahrzeug-Waffen-Hash (falls das Event doch feuert) direkt als VDM
    if Config.Detect.VDM and (ev.weapon == WEAPON_RUN_OVER or ev.weapon == WEAPON_RAMMED) then
        local veh = GetVehiclePedIsIn(GetPlayerPed(shooter), false)
        local speed = veh ~= 0 and GetEntitySpeed(veh) or 0.0
        Detection.FlagVDM(shooter, victim, speed)
        return
    end

    -- == Spawn-Kill ==
    if Config.Detect.SpawnKill and ev.willKill then
        local sp = spawnedAt[victim]
        if sp and (now - sp) <= Config.SpawnKillSeconds * 1000 then
            createIncident('spawnkill', 0.7, { shooter = shooter, victim = victim }, {
                sinceSpawn = (now - sp) / 1000.0,
                summary = ('%s toetet %s %.1fs nach dessen Spawn'):format(
                    nameOf(shooter), nameOf(victim), (now - sp) / 1000.0),
            })
            return
        end
    end

    -- == RDM ==
    if Config.Detect.RDM and ev.willKill then
        local contact = Interactions.HadContact(shooter, victim, Config.RdmLookbackMinutes * 60000)
        local proxSecs = Interactions.ProximitySeconds(shooter, victim)
        local dist = ev.dist or 0.0

        if not contact and dist >= Config.RdmMinDistance then
            -- Konfidenz steigt mit Distanz und fehlender Naehe-Zeit
            local conf = 0.55
                + math.min(0.25, dist / 200)
                + (proxSecs < 1 and 0.15 or 0.0)
            createIncident('rdm', conf, { shooter = shooter, victim = victim }, {
                dist = dist, proximitySecs = proxSecs,
                summary = ('%s toetet %s auf %.0fm ohne Vorkontakt'):format(
                    nameOf(shooter), nameOf(victim), dist),
            })
        end
    end
end)

-- == Combat-Log: Disconnect nach Kampf ==

AddEventHandler('playerDropped', function(reason)
    local src = source
    if not Config.Detect.CombatLog then return end

    local lc = lastCombat[src]
    if lc and (GetGameTimer() - lc) <= Config.CombatLogSeconds * 1000 then
        -- Timeout vs. bewusstes Verlassen unterscheiden
        local intentional = not (reason and reason:lower():find('time'))
        createIncident('combatlog', intentional and 0.85 or 0.5,
            { shooter = src }, {
                reason = reason, intentional = intentional,
                sinceCombat = (GetGameTimer() - lc) / 1000.0,
                summary = ('%s verlaesst den Server %.0fs nach Kampf (%s)'):format(
                    nameOf(src), (GetGameTimer() - lc) / 1000.0,
                    intentional and 'bewusst' or 'Timeout?'),
            })
    end
    lastCombat[src] = nil; spawnedAt[src] = nil
end)

-- == NLR: Rueckkehr an den Todesort ==

CreateThread(function()
    while true do
        Wait(3000)
        if Recording and Config.Detect.NLR then
            local now = os.time()
            for _, sp in ipairs(GetPlayers()) do
                local src = tonumber(sp)
                local di = deathInfo[src]
                if di and (now - di.t) <= Config.NlrMinutes * 60 then
                    local ped = GetPlayerPed(src)
                    if ped ~= 0 and DoesEntityExist(ped) then
                        local d = #(GetEntityCoords(ped) - di.pos)
                        if not di.hasLeft then
                            -- Erst muss der Spieler den Todesort verlassen, sonst ist "am Todesort" nur der normale Respawn
                            if d > Config.NlrReturnMeters then di.hasLeft = true end
                        elseif d <= Config.NlrReturnMeters and d > 1.0 then
                            -- War weg, kehrt zurueck -> echter NLR-Verstoss
                            createIncident('nlr', 0.65, { shooter = src }, {
                                sinceDeath = (now - di.t),
                                summary = ('%s kehrt %.0fs nach Tod an den Todesort zurueck (%.0fm)'):format(
                                    nameOf(src), now - di.t, d),
                            })
                            deathInfo[src] = nil   -- nur einmal flaggen
                        end
                    end
                elseif di and (now - di.t) > Config.NlrMinutes * 60 then
                    deathInfo[src] = nil
                end
            end
        end
    end
end)

return Detection
