--[[ ===========================================================================
    D-RPS — Dollar Replay System
    client/fidelity.lua

    Sammelt fortlaufend, was nur der Client ueber den EIGENEN Ped weiss, und
    schickt es gebuendelt an den Server (fremde Entities waeren lueckenhaft, §3.8).
=========================================================================== ]]

local prev, parts, nParts = nil, {}, 0
local chunkStartSec, chunkStartMs, chunkStartTimer = 0, 0, 0
local lastTimer = 0

-- ── Zustand des eigenen Peds lesen ─────────────────────────────────────────

local function readFidelity()
    local ped = PlayerPedId()
    local P, V = Fidelity.P, Fidelity.V

    local flags = 0
    if IsPedWalking(ped)            then flags = flags | P.WALKING   end
    if IsPedRunning(ped)            then flags = flags | P.RUNNING   end
    if IsPedSprinting(ped)          then flags = flags | P.SPRINTING end
    if IsPedJumping(ped)            then flags = flags | P.JUMPING   end
    if IsPedInCover(ped, false)     then flags = flags | P.IN_COVER  end
    if IsPlayerFreeAiming(PlayerId()) then flags = flags | P.AIMING  end
    if IsPedShooting(ped)           then flags = flags | P.SHOOTING  end
    if IsPedReloading(ped)          then flags = flags | P.RELOADING end
    if IsPedRagdoll(ped)            then flags = flags | P.RAGDOLL   end
    if IsPedSwimming(ped)           then flags = flags | P.SWIMMING  end
    if IsPedClimbing(ped)           then flags = flags | P.CLIMBING  end
    -- GetPedStealthMovement liefert einen Wahrheitswert, keine 1 (Test gegen 1 war nie wahr).
    if GetPedStealthMovement(ped)   then flags = flags | P.CROUCH    end
    if IsPedFalling(ped)            then flags = flags | P.FALLING   end
    if IsPedInParachuteFreeFall(ped) then flags = flags | P.PARACHUTE end

    -- Blickrichtung inkl. Neigung: das, was der Server verwirft.
    local rot = GetFinalRenderedCamRot(2)

    local steer, vflags = 0.0, 0
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 then
        flags = flags | P.IN_VEH
        if GetPedInVehicleSeat(veh, -1) == ped then flags = flags | P.DRIVER end

        steer = GetVehicleSteeringAngle(veh)
        -- GetVehicleLightsState gibt DREI Werte: Rueckgabewert, Abblend-, Fernlicht.
        local _, lowOn, highOn = GetVehicleLightsState(veh)
        if lowOn  == 1 or lowOn  == true then vflags = vflags | V.LIGHTS   end
        if highOn == 1 or highOn == true then vflags = vflags | V.HIGHBEAM end
        local indic = GetVehicleIndicatorLights(veh)
        if indic & 1 ~= 0 then vflags = vflags | V.INDIC_R end
        if indic & 2 ~= 0 then vflags = vflags | V.INDIC_L end
        if IsVehicleSirenOn(veh)        then vflags = vflags | V.SIREN  end
        if GetVehicleHandbrake(veh)     then vflags = vflags | V.BRAKING end
        if GetVehicleEngineHealth(veh) > 0 and GetIsVehicleEngineRunning(veh) then
            vflags = vflags | V.ENGINE
        end
        for d = 0, 3 do
            if GetVehicleDoorAngleRatio(veh, d) > 0.05 then
                vflags = vflags | V.DOOR_OPEN; break
            end
        end
    end

    return {
        flags   = flags,
        camYaw  = rot.z, camPitch = rot.x,
        blend   = GetPedDesiredMoveBlendRatio(ped),
        heading = GetEntityHeading(ped),
        steer   = steer, vflags = vflags,
        weapon  = GetSelectedPedWeapon(ped) & 0xFFFFFFFF,
        ammo    = GetAmmoInPedWeapon(ped, GetSelectedPedWeapon(ped)) or 0,
    }
end

-- ── Zeitachse vom Server ───────────────────────────────────────────────────
-- Der Client braucht dasselbe Segmentraster wie der Server (sonst decken Chunks
-- zwei Segmente ab und die Ein-Segment-Regel bricht). Versatz EINMAL bestimmt
-- (Serverzeit gegen Uptime); danach nur GetGameTimer (einzige monotone Uhr).

local segEpoch, segSec, clockOffset = nil, nil, nil
local chunkSeg = nil

RegisterNetEvent('d-rps:session', function(epoch, sec, serverNowSec)
    if type(epoch) ~= 'number' or type(sec) ~= 'number' or sec <= 0 then return end
    segEpoch = math.floor(epoch)
    segSec   = math.floor(sec)
    if type(serverNowSec) == 'number' and serverNowSec > 0 then
        clockOffset = math.floor(serverNowSec) - (GetGameTimer() // 1000)
    end
end)

--- Segmentnummer zu einem Uptime-Wert. nil bis der Server sich meldet
--- (dann Rueckfall auf die feste Chunklaenge).
local function segOfTimer(t)
    if not segEpoch or not segSec or not clockOffset then return nil end
    local sec = (t // 1000) + clockOffset
    if sec <= segEpoch then return 0 end
    return (sec - segEpoch) // segSec
end

-- ── Chunk schliessen und hochladen ─────────────────────────────────────────

local function flush()
    if nParts == 0 then return end
    local chunk = Fidelity.EncodeChunkHeader(chunkStartSec, chunkStartMs, 0, nParts)
                .. table.concat(parts, '', 1, nParts)
    TriggerServerEvent('d-rps:fidelity', chunk)
    parts, nParts, prev = {}, 0, nil
end

-- ── Aufzeichnung ───────────────────────────────────────────────────────────

CreateThread(function()
    Wait(6000)   -- Charakter laden lassen
    lastTimer = GetGameTimer()

    while true do
        Wait(Config.FidelityIntervalMs)
        if Config.Fidelity then
            local now = GetGameTimer()
            local dt  = now - lastTimer
            if dt > 65535 then dt = 65535 end
            lastTimer = now

            local ok, s = pcall(readFidelity)
            if ok and s then
                if prev then
                    nParts = nParts + 1
                    parts[nParts] = Fidelity.EncodeDelta(prev, s, dt)
                else
                    -- Erster Sample: absoluter Bezugspunkt (Unix-Zeit vom Spiel;
                    -- faellt sie aus, korrigiert der Server sie beim Empfang).
                    local okT, cloud = pcall(GetCloudTimeAsInt)
                    chunkStartSec   = (okT and cloud and cloud > 0) and math.floor(cloud) or 0
                    chunkStartMs    = now % 1000
                    chunkStartTimer = now
                    chunkSeg        = segOfTimer(now)
                    nParts = 1
                    parts[1] = Fidelity.EncodeKeyframe(s, 0)
                end
                prev = s

                -- An der Segmentgrenze schliessen: ein Chunk je Segment (wie im
                -- Recorder). Feste Chunklaenge bleibt Obergrenze ohne Servermeldung.
                local nowSeg = segOfTimer(now)
                if (nowSeg and chunkSeg and nowSeg ~= chunkSeg)
                   or (now - chunkStartTimer) >= (Config.DiskChunkSeconds * 1000) then
                    flush()
                end
            end
        end
    end
end)

-- Beim Verlassen den offenen Rest noch mitgeben.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then flush() end
end)

--- Die Zeitachse der Aufzeichnung, fuer andere Client-Module.
--- Es darf nur EINE Uhr geben: ein zweites Modul mit eigener Zeit liesse Chunks
--- im falschen Segment landen. Rueckgabe: epoch, segSec, clockOffset — oder nil
--- bis der Server sich meldet.
function RPSClientClock()
    return segEpoch, segSec, clockOffset
end
