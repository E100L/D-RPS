--[[ D-RPS — client/playback.lua
     3D-Playback-Engine: spielt die Aufzeichnung als lokale Klone
     (isNetwork=false) auf gemeinsamer Zeitachse aus dem Segment-Cache ab.
     Zeitquellen nicht mischen: GetGameTimer=Uptime nur fuer Spannen,
     Wanduhrzeiten kommen aus dem Manifest (clientseitig kein os/io). ]]

local active   = false
local playing  = true
local speed    = 1.0          -- Wiedergabetempo
local playDir  = 1            -- Laufrichtung (Shuttle J/K/L)
local playT    = 0.0          -- Wiedergabezeit, relativ zu Segments.T0
local duration = 0.0
local scrubbing = false       -- true = exakte Positionierung statt Lokomotion
local buffering = false       -- true = warten auf Material, Zeit steht still
local actors   = {}
local focusIdx = 1
local incidents, worldLog = {}, {}
local damageEvents = {}         -- Schadensereignisse fuer das Datenband
local timeBase = 0              -- absolute Unix-Zeit von playT = 0
local activeIncidentId = nil
local scrubUntil = 0            -- bis wann exakt positioniert wird
local seekHold   = false        -- nach einem Sprung: puffern statt stolpern
local seekHoldTo = 0
-- Puffer-Obergrenze nach einem Sprung: kommt nichts, laeuft es trotzdem weiter.
local SEEK_HOLD_MAX_MS = 4000
local chatBlockUntil = 0        -- kurz nach dem Oeffnen keine Kuerzel annehmen
local sceneClockLabel, sceneWeatherLabel = '—', '—'
local adminName = '?'          -- eigener Name, fuer "Mir zuweisen"

-- Sitzungszaehler: das faule Spawnen gibt beim Modellladen ab; ein neues
-- Manifest darf danach keinen Klon hinterlassen, den teardown() nie findet.
local sessionGen = 0

-- Ab diesem Spannenabstand wird im Datenband eine Luecke gezeichnet.
local GAP_SECONDS = Config.SegmentGapSeconds or 5.0

-- Deckkraft eines nachladenden Klons: sichtbar, aber nicht "weg".
local STALE_ALPHA = 120

local cam = nil
local camPos, camYaw, camPitch = nil, 0.0, 0.0
local followMode  = true
local cursorMode  = false
local orbitYaw, orbitPitch, orbitDist = 0.0, 18.0, 6.0
local lastTargetPos = nil

-- ── Mathe ──────────────────────────────────────────────────────────────────

local function lerp(a, b, f) return a + (b - a) * f end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function lerpHeading(a, b, f)
    local d = ((b - a + 180.0) % 360.0) - 180.0
    return (a + d * f) % 360.0
end

local function rotToDir(pitch, yaw)
    local rx, rz = math.rad(pitch), math.rad(yaw)
    local cosrx = math.cos(rx)
    return vector3(-math.sin(rz) * cosrx, math.cos(rz) * cosrx, math.sin(rx))
end

local function aimAt(from, target)
    local d = target - from
    local len = #d
    if len < 0.01 then return camYaw or 0.0, camPitch or 0.0 end
    return math.deg(math.atan(-d.x, d.y)), math.deg(math.asin(d.z / len))
end

--- Positive Config-Zahl. Sucht zuerst in Config.Playback, dann auf oberster
--- Ebene; fehlender/ungueltiger Wert faellt auf dflt zurueck.
local function cfgNum(key, dflt)
    local v = tonumber(Config and Config.Playback and Config.Playback[key])
    if not v then v = tonumber(Config and Config[key]) end
    if not v or v ~= v or v <= 0 then return dflt end
    return v
end

-- ── Abtasten ueber den Segment-Cache ───────────────────────────────────────
-- Der Cache haelt Zustaende als parallele Zahlenarrays und liefert Indizes.
-- Die Darstellung braucht Felder: jeder Actor hat drei feste Schreibtische
-- (s1, s2, fs), die je Bild ueberschrieben werden — keine Tabelle je Sample.

--- Zustandspaar in die Schreibtische des Actors legen.
local function fillEv(a, p, i1, i2)
    local s1, s2 = a.s1, a.s2
    s1.relT     = p.sT[i1];        s2.relT     = p.sT[i2]
    s1.x        = p.sX[i1];        s2.x        = p.sX[i2]
    s1.y        = p.sY[i1];        s2.y        = p.sY[i2]
    s1.z        = p.sZ[i1];        s2.z        = p.sZ[i2]
    s1.heading  = p.sHeading[i1];  s2.heading  = p.sHeading[i2]
    s1.health   = p.sHealth[i1];   s2.health   = p.sHealth[i2]
    s1.armour   = p.sArmour[i1];   s2.armour   = p.sArmour[i2]
    s1.flags    = p.sFlags[i1];    s2.flags    = p.sFlags[i2]
    s1.vehModel = p.sVehModel[i1]; s2.vehModel = p.sVehModel[i2]
    s1.vehSeat  = p.sVehSeat[i1];  s2.vehSeat  = p.sVehSeat[i2]
    s1.speed    = p.sSpeed[i1];    s2.speed    = p.sSpeed[i2]
    s1.steer    = p.sSteer[i1];    s2.steer    = p.sSteer[i2]
    s1.vpitch   = p.sVPitch[i1];   s2.vpitch   = p.sVPitch[i2]
    s1.vroll    = p.sVRoll[i1];    s2.vroll    = p.sVRoll[i2]
    return s1, s2
end

--- Fidelity-Zustand in den Schreibtisch legen. Nicht interpoliert: Schaltbits.
local function fillFid(a, p, i)
    local fs = a.fs
    fs.flags    = p.fFlags[i]    or 0
    fs.camYaw   = p.fCamYaw[i]   or 0.0
    fs.camPitch = p.fCamPitch[i] or 0.0
    fs.blend    = p.fBlend[i]    or 0.0
    fs.heading  = p.fHeading[i]  or 0.0
    fs.steer    = p.fSteer[i]    or 0.0
    fs.vflags   = p.fVFlags[i]   or 0
    fs.weapon   = p.fWeapon[i]   or 0
    fs.ammo     = p.fAmmo[i]     or 0
    return fs
end

--- Zeitpunkt der Wiedergabe auf der Zeitachse des Manifests.
local function segTime(t) return (Segments.T0 or 0) + t end

--- Zustandspaar zum Zeitpunkt t. Vierter Rueckgabewert ist der Zustand des
--- Caches: 'ok', 'stale' (laedt noch) oder 'gap' (war nicht da).
local function sampleAt(a, t)
    if not a or not a.hash then return nil, nil, 0.0, 'gap' end
    local i1, i2, f, st = Segments.SampleAt(a.hash, segTime(t))
    if st ~= 'ok' or not i1 then return nil, nil, 0.0, st or 'gap' end
    local s1, s2 = fillEv(a, a.p, i1, i2)
    return s1, s2, f or 0.0, 'ok'
end

--- Fidelity-Sample zum Zeitpunkt t, oder nil.
local function fidAt(a, t)
    if not a or not a.hash then return nil end
    local i = Segments.FidAt(a.hash, segTime(t))
    if not i then return nil end
    return fillFid(a, a.p, i)
end

--- Bewegungszustand aus den Fidelity-Bits auf den Klon uebertragen.
local function applyFidelityPed(a, fs)
    local ped, P = a.clonePed, Fidelity.P
    if not fs or not ped or not DoesEntityExist(ped) then return end

    -- Gefuehrte Waffe sichtbar machen
    if fs.weapon and fs.weapon ~= 0 and fs.weapon ~= a.lastWeapon then
        a.lastWeapon = fs.weapon
        pcall(function()
            GiveWeaponToPed(ped, fs.weapon, 250, false, true)
            SetCurrentPedWeapon(ped, fs.weapon, true)
        end)
    end

    -- Bewegungsart aus den Bits: der Server kennt nur die Strecke.
    local motion
    if fs.flags & P.SPRINTING ~= 0 then motion = 'CTaskHumanLocomotion'
    elseif fs.flags & P.RUNNING ~= 0 then motion = 'CTaskHumanLocomotion'
    elseif fs.flags & P.WALKING ~= 0 then motion = 'CTaskHumanLocomotion'
    elseif fs.flags & P.AIMING ~= 0  then motion = 'CTaskMotionAiming'
    else motion = 'CTaskMotionIdle' end

    if motion ~= a.lastMotion then
        a.lastMotion = motion
        pcall(ForcePedMotionState, ped, GetHashKey(motion), false, 0, false)
    end

    -- Geduckt gehen
    SetPedStealthMovement(ped, (fs.flags & P.CROUCH) ~= 0, 'DEFAULT_ACTION')

    -- Exakte Gangart-Mischung statt Schaetzung aus der Strecke.
    if fs.blend and math.abs((a.lastBlend or -1) - fs.blend) > 0.05 then
        a.lastBlend = fs.blend
        SetPedDesiredMoveBlendRatio(ped, fs.blend)
    end
end

--- Fahrzeugdetails aus dem Fidelity-Strom: Lenkung, Licht, Blinker, Sirene.
local function applyFidelityVehicle(a, fs)
    local v, V = a.cloneVeh, Fidelity.V
    if not fs or not v or not DoesEntityExist(v) then return end

    pcall(function() Citizen.InvokeNative(0xFFCCC2EA, v, fs.steer or 0.0) end)

    local lights   = (fs.vflags & V.LIGHTS)   ~= 0
    local highbeam = (fs.vflags & V.HIGHBEAM) ~= 0
    SetVehicleLights(v, lights and (highbeam and 3 or 2) or 1)
    SetVehicleIndicatorLights(v, 0, (fs.vflags & V.INDIC_R) ~= 0)   -- rechts
    SetVehicleIndicatorLights(v, 1, (fs.vflags & V.INDIC_L) ~= 0)   -- links
    SetVehicleSiren(v, (fs.vflags & V.SIREN) ~= 0)
    SetVehicleBrakeLights(v, (fs.vflags & V.BRAKING) ~= 0)
end

--- Position des verfolgten Spielers, oder nil (Luecke/noch nicht geladen).
local function focusPos()
    local a = actors[focusIdx]
    if not a then return nil end
    local s1, s2, f = sampleAt(a, playT)
    if not s1 then return nil end
    return vector3(lerp(s1.x, s2.x, f), lerp(s1.y, s2.y, f), lerp(s1.z, s2.z, f))
end

-- ── Aussehen ───────────────────────────────────────────────────────────────

--- Vollstaendiges Aussehen aus der Skin-Tabelle auf einen Klon uebertragen.
--- 1:1-Nachbildung von skinchanger (das fest den Spieler-Ped setzt, nicht einen
--- Klon); Zahlen und Reihenfolge exakt uebernommen. Felder sind flache,
--- 1-basierte Arrays — 0-indizierte ueberleben die Netzgrenze nicht.
local function applySkin(ped, c)
    if type(c) ~= 'table' then return end
    local function n(key, dflt) local v = c[key]; return (type(v) == 'number') and v or (dflt or 0) end

    -- Kopf: Eltern fuer Form UND Haut, dazu die drei Mischgewichte (0..100 → 0..1).
    pcall(SetPedHeadBlendData, ped,
        math.floor(n('mom')), math.floor(n('dad')), math.floor(n('grandparents')),
        math.floor(n('mom')), math.floor(n('dad')), math.floor(n('grandparents')),
        n('face_md_weight', 50) / 100.0, n('skin_md_weight', 50) / 100.0,
        n('face_g_weight', 0) / 100.0, false)

    -- Gesichtsregler (−1..1), Reihenfolge wie skinchanger.
    local FACE = { 'nose_1','nose_2','nose_3','nose_4','nose_5','nose_6',
        'eyebrows_5','eyebrows_6','cheeks_1','cheeks_2','cheeks_3','eye_squint',
        'lip_thickness','jaw_1','jaw_2','chin_1','chin_2','chin_3','chin_4','neck_thickness' }
    for i = 1, #FACE do
        pcall(SetPedFaceFeature, ped, i - 1, n(FACE[i]) / 10.0)
    end
    pcall(SetPedEyeColor, ped, math.floor(n('eye_color')))

    -- Auflagen: Index + Deckkraft (0..10 → 0..1). Hier steckt die Bartstaerke.
    local OVER = { {'blemishes_1','blemishes_2'}, {'beard_1','beard_2'},
        {'eyebrows_1','eyebrows_2'}, {'age_1','age_2'}, {'makeup_1','makeup_2'},
        {'blush_1','blush_2'}, {'complexion_1','complexion_2'}, {'sun_1','sun_2'},
        {'lipstick_1','lipstick_2'}, {'moles_1','moles_2'}, {'chest_1','chest_2'} }
    for i = 1, #OVER do
        pcall(SetPedHeadOverlay, ped, i - 1, math.floor(n(OVER[i][1])), n(OVER[i][2]) / 10.0)
    end

    -- Auflagenfarben (Bart, Augenbrauen, Make-up, …), FarbTyp fest 1.
    local COL = { [1] = {'beard_3','beard_4'}, [2] = {'eyebrows_3','eyebrows_4'},
        [4] = {'makeup_3','makeup_4'}, [5] = {'blush_3', nil},
        [8] = {'lipstick_3','lipstick_4'}, [10] = {'chest_3', nil} }
    for i, f in pairs(COL) do
        pcall(SetPedHeadOverlayColor, ped, i, 1, math.floor(n(f[1])),
              f[2] and math.floor(n(f[2])) or 0)
    end

    -- Haare (Komponente 2) und Haarfarbe.
    pcall(SetPedComponentVariation, ped, 2, math.floor(n('hair_1')), math.floor(n('hair_2')), 2)
    pcall(SetPedHairColor, ped, math.floor(n('hair_color_1')), math.floor(n('hair_color_2')))

    -- Kleidung: skinchanger-Zuordnung Name → Komponenten-Slot.
    local COMP = { {'tshirt_1','tshirt_2',8}, {'torso_1','torso_2',11},
        {'decals_1','decals_2',10}, {'arms','arms_2',3}, {'pants_1','pants_2',4},
        {'shoes_1','shoes_2',6}, {'mask_1','mask_2',1}, {'bproof_1','bproof_2',9},
        {'chain_1','chain_2',7}, {'bags_1','bags_2',5} }
    for i = 1, #COMP do
        pcall(SetPedComponentVariation, ped, COMP[i][3],
              math.floor(n(COMP[i][1])), math.floor(n(COMP[i][2])), 2)
    end

    -- Accessoires: −1 heisst "keins".
    local PROP = { {'helmet_1','helmet_2',0}, {'glasses_1','glasses_2',1},
        {'ears_1','ears_2',2}, {'watches_1','watches_2',6}, {'bracelets_1','bracelets_2',7} }
    for i = 1, #PROP do
        local v = math.floor(n(PROP[i][1], -1))
        if v < 0 then pcall(ClearPedProp, ped, PROP[i][3])
        else pcall(SetPedPropIndex, ped, PROP[i][3], v, math.floor(n(PROP[i][2])), true) end
    end
end

local function applyAppearance(ped, ap)
    if not ap then return end

    -- Skin-Tabelle gilt, wenn vorhanden; Native-Weg ist der Rueckfall.
    if ap.skin then applySkin(ped, ap.skin); return end

    -- Reihenfolge tragend: erst Gesicht, dann Kleidung. SetPedHeadBlendData
    -- setzt den Kopf neu und wirft Variationen zurueck.
    local hd = ap.head
    if hd then
        pcall(SetPedHeadBlendData, ped,
            math.floor(hd[1] or 0), math.floor(hd[2] or 0), math.floor(hd[3] or 0),
            math.floor(hd[4] or 0), math.floor(hd[5] or 0), math.floor(hd[6] or 0),
            (hd[7] or 0.5) + 0.0, (hd[8] or 0.5) + 0.0, (hd[9] or 0.0) + 0.0, false)
    end

    if ap.face then
        for i = 0, 19 do
            local v = ap.face[i + 1]
            if v then pcall(SetPedFaceFeature, ped, i, v + 0.0) end
        end
    end

    -- Haarfarbe zuerst bestimmen: Bart, Augenbrauen und Brusthaar teilen sie.
    local hairMain = ap.hair and math.floor(ap.hair[1] or 0) or 0
    local hairHigh = ap.hair and math.floor(ap.hair[2] or 0) or 0

    if ap.over then
        for i = 0, 12 do
            local k = i * 5
            local val = ap.over[k + 1]
            -- 255 heisst "keine Auflage". Nur echte Auflagen setzen.
            if val and val ~= 255 then
                -- Deckkraft: das Auslese-Native liefert sie manchmal als 0,
                -- obwohl sichtbar — dann volle Deckkraft statt unsichtbar.
                local op = ap.over[k + 5]
                if type(op) ~= 'number' or op <= 0.0 or op > 1.0 then op = 1.0 end
                pcall(SetPedHeadOverlay, ped, i, math.floor(val), op + 0.0)

                -- Farbe: gemeldeter FarbTyp unbrauchbar. Haartragende Auflagen
                -- (Bart 1, Augenbrauen 2, Brusthaar 10) fest FarbTyp 1 +
                -- Haarfarbe, Rest ungefaerbt (Typ 0).
                local ct, c1, c2 = 0, 0, 0
                if i == 1 or i == 2 or i == 10 then
                    ct, c1, c2 = 1, hairMain, hairHigh
                end
                pcall(SetPedHeadOverlayColor, ped, i, ct, c1, c2)
            end
        end
    end

    if ap.hair then
        pcall(SetPedHairColor, ped, hairMain, hairHigh)
    end
    if ap.eyes then pcall(SetPedEyeColor, ped, math.floor(ap.eyes)) end

    if ap.comp then
        for i = 0, 11 do
            local k = i * 3
            local d = ap.comp[k + 1]
            if d then
                SetPedComponentVariation(ped, i, math.floor(d),
                    math.floor(ap.comp[k + 2] or 0), math.floor(ap.comp[k + 3] or 0))
            end
        end
    end

    if ap.prop then
        for i = 0, 7 do
            local k = i * 2
            local d = ap.prop[k + 1]
            if d then
                if d < 0 then ClearPedProp(ped, i)
                else SetPedPropIndex(ped, i, math.floor(d), math.floor(ap.prop[k + 2] or 0), true) end
            end
        end
    end
end

-- ── Fahrzeug-Klon ──────────────────────────────────────────────────────────

local function removeVehicle(a)
    if a.cloneVeh and DoesEntityExist(a.cloneVeh) then
        SetEntityAsMissionEntity(a.cloneVeh, true, true)
        DeleteVehicle(a.cloneVeh)
    end
    a.cloneVeh = nil; a.curVehModel = 0
    a.alphaVeh, a.alphaEnt = nil, nil
    a.vehFrozen = false
    a.inVeh = false
end

--- Ein Modell laden. Fehlschlag wird in a.badModels gemerkt, sonst kostet ein
--- nicht ladbares Add-on-Fahrzeug jeden Frame eine Sekunde Wartezeit.
local function loadModel(a, model, wantVehicle)
    if a.badModels and a.badModels[model] then return false end
    a.badModels = a.badModels or {}

    if not IsModelValid(model) or (wantVehicle and not IsModelAVehicle(model)) then
        a.badModels[model] = true
        return false
    end
    if HasModelLoaded(model) then return true end

    RequestModel(model)
    local t = 0
    while not HasModelLoaded(model) and t < 100 do Wait(10); t = t + 1 end
    if not HasModelLoaded(model) then
        a.badModels[model] = true
        SetModelAsNoLongerNeeded(model)
        return false
    end
    return true
end

--- Klon gegen Zuschauer und andere Klone isolieren (nur bei Kollision).
--- Paare gelten beidseitig, daher jede Beziehung zweimal.
function isolateClone(ent)
    if not ent or not DoesEntityExist(ent) then return end
    pcall(function()
        local me = PlayerPedId()
        SetEntityNoCollisionEntity(ent, me, true)
        SetEntityNoCollisionEntity(me, ent, true)
        for _, o in ipairs(actors) do
            for _, other in ipairs({ o.clonePed, o.cloneVeh }) do
                if other and other ~= ent and DoesEntityExist(other) then
                    SetEntityNoCollisionEntity(ent, other, true)
                    SetEntityNoCollisionEntity(other, ent, true)
                end
            end
        end
    end)
end

local function ensureVehicle(a, model, seat)
    if a.cloneVeh and DoesEntityExist(a.cloneVeh) and a.curVehModel == model then return end
    if a.badModels and a.badModels[model] then return end
    removeVehicle(a)

    -- loadModel gibt beim Streamen ab; danach pruefen, ob die Sitzung noch gilt.
    local myGen = sessionGen
    if not loadModel(a, model, true) then return end
    if sessionGen ~= myGen or not active then return end

    local pos = GetEntityCoords(a.clonePed)
    a.cloneVeh = CreateVehicle(model, pos.x, pos.y, pos.z, 0.0, false, false)
    SetModelAsNoLongerNeeded(model)

    -- Fahrzeugpool erschoepft -> CreateVehicle liefert 0. Kein badModels-Eintrag,
    -- der naechste Frame darf erneut versuchen.
    if not a.cloneVeh or a.cloneVeh == 0 or not DoesEntityExist(a.cloneVeh) then
        a.cloneVeh = nil
        return
    end

    SetEntityInvincible(a.cloneVeh, true)
    SetVehicleDoorsLocked(a.cloneVeh, 4)

    -- Versuchsmodus: Akteursfahrzeug wie ein Weltfahrzeug aufbauen.
    if Config.Playback.VehicleFreeze then
        SetVehicleEngineOn(a.cloneVeh, false, true, true)
        FreezeEntityPosition(a.cloneVeh, true)
        a.vehFrozen = true
    else
        SetVehicleEngineOn(a.cloneVeh, true, true, false)
    end

    -- Physik-Betriebsart (Config.Playback.VehiclePhysicsMode). Ohne Kollision
    -- tastet die Engine die Radaufhaengung nicht ab; im Fahrbetrieb daher Pflicht.
    local mode = Config.Playback.VehiclePhysicsMode or 'collision'
    if Config.Playback.VehicleDrive then mode = 'collision' end
    if mode == 'collision' then
        SetEntityCollision(a.cloneVeh, true, true)
    elseif mode == 'keep' then
        SetEntityCollision(a.cloneVeh, false, true)
    else
        SetEntityCollision(a.cloneVeh, false, false)
    end

    SetVehicleWheelsCanBreak(a.cloneVeh, false)
    SetVehicleHasBeenOwnedByPlayer(a.cloneVeh, true)
    SetVehicleCanBeVisiblyDamaged(a.cloneVeh, false)
    -- Ein toter Ped laesst sich nicht in einen Sitz setzen. Erst wiederbeleben;
    -- die Todesdarstellung wird im selben Bild ohnehin neu gesetzt.
    if a.seatDead then
        a.seatDead = false
        if IsPedDeadOrDying(a.clonePed, true) then ResurrectPed(a.clonePed) end
        SetEntityInvincible(a.clonePed, true)
    end
    SetPedIntoVehicle(a.clonePed, a.cloneVeh, seat or -1)
    -- a.inVeh messen statt behaupten: die Engine nimmt Peds auf Wegen aus dem
    -- Sitz, die diese Buchfuehrung nicht sieht.
    a.inVeh = IsPedInVehicle(a.clonePed, a.cloneVeh, false)
    a.curVehModel = model

    if mode == 'collision' then isolateClone(a.cloneVeh) end

    a.lastVehPos  = nil
    a.posLead     = nil
    a.posLeadMax  = nil
    a.vehFrozen   = false
    a.wheelCount  = nil     -- je Modell neu bestimmen
    a.wheelRadius = nil
end

-- ── Radrotation ────────────────────────────────────────────────────────────

--- Radzahl und Reifenradius je Modell einmal bestimmen.
local function ensureWheelInfo(a, veh)
    if a.wheelCount then return end
    local okN, n = pcall(GetVehicleNumberOfWheels, veh)
    a.wheelCount  = (okN and type(n) == 'number' and n > 0) and n or 4
    a.wheelRadius = {}
    for i = 0, a.wheelCount - 1 do
        local okR, r = pcall(GetVehicleWheelTireColliderSize, veh, i)
        -- Native liefert den Radius (nicht Durchmesser); 0.35 m PKW-Rueckfall.
        a.wheelRadius[i] = (okR and type(r) == 'number' and r > 0.05) and r or 0.35
    end
end

--- Messpunkt, muss VOR dem Teleport dieses Frames laufen (sonst misst man nur,
--- was den Teleport ueberlebt hat).
local function probeWheels(a, veh)
    local okPrev, prev = pcall(GetVehicleWheelRotationSpeed, veh, 0)
    a.wheelPrev = okPrev and prev or nil

    local okB, bp = pcall(GetVehicleWheelBrakePressure, veh, 0)
    a.wheelBrake = okB and bp or nil

    -- Positionsvorlauf: hat die Engine den Koerper seit dem Teleport bewegt?
    -- Als Vektor merken, damit er im selben Frame herausgerechnet werden kann.
    if a.lastVehPos then
        local d = GetEntityCoords(veh) - a.lastVehPos
        a.leadVec    = d
        a.posLead    = #d
        a.posLeadMax = math.max(a.posLeadMax or 0.0, a.posLead)
    else
        a.leadVec = nil
    end
end

--- Bremsen loesen. Ein besetztes Fahrzeug ohne Fahrauftrag wird von der Engine
--- festgehalten (Handbremse + Bremsdruck); ein gebremstes Rad dreht nicht.
local function releaseBrakes(a, veh)
    if not Config.Playback.VehicleReleaseBrakes then return end
    pcall(SetVehicleHandbrake, veh, false)
    for i = 0, (a.wheelCount or 4) - 1 do
        pcall(SetVehicleWheelBrakePressure, veh, i, 0.0)
    end
end

--- Zweiter Schreibweg auf die Radrotation: SetVehicleForwardSpeed setzt auch
--- die Raddrehzahl. Vor der Geschwindigkeitszuweisung, weil es sie mitsetzt.
local function pushWheels(a, veh, speedMs)
    if not Config.Playback.VehicleWheelPush then return end
    pcall(SetVehicleForwardSpeed, veh, speedMs + 0.0)
end

-- ── Fahren statt versetzen ─────────────────────────────────────────────────
-- Ein versetztes Fahrzeug behandelt die Engine als Requisite: keine Rad-
-- rotation. Deshalb wird stattdessen GEFAHREN — Geschwindigkeit aus der Bahn
-- vorgeben, die Physik rechnet den Rest, die Raeder rollen echt. Preis:
-- einige Dezimeter Versatz statt zwei Zentimeter (fuer ein Entscheidungs-
-- werkzeug die richtige Abwaegung). Direktes Setzen der Radrotation ist eine
-- Sackgasse (nicht wieder aufmachen). Drei Bereiche gegen Schwingen:
--   unter DriveCorrectionSoft — rollen lassen; darueber — Soll plus Korrektur;
--   ueber DriveTeleportAt — echter Sprung.
local function driveVehicle(a, v, s1, s2, x, y, z, h, rate)
    local soft = cfgNum('DriveCorrectionSoft', 0.6)
    local gain = cfgNum('DriveCorrectionGain', 4.0)
    local hard = cfgNum('DriveTeleportAt', 8.0)

    local cur = GetEntityCoords(v)
    local ex, ey, ez = x - cur.x, y - cur.y, z - cur.z

    -- Waagerecht und senkrecht getrennt: die Federung haelt den Klon dauerhaft
    -- ein paar cm neben der Hoehe, das triebe einen gemeinsamen Fehler an.
    local errH = math.sqrt(ex * ex + ey * ey)
    local errZ = math.abs(ez)
    a.driveErr = errH

    -- Steht das Bild oder wird gezogen: hart setzen statt fahren.
    local still = (not playing) or scrubbing or buffering or (rate == 0.0)

    -- Senkrecht grosszuegiger: Rampe/Bordstein/Bruecke sind kein Fehler.
    if errH >= hard or errZ >= (hard * 1.5) or still then
        SetEntityCoordsNoOffset(v, x, y, z, false, false, false)
        SetEntityRotation(v, s1.vpitch or 0.0, s1.vroll or 0.0, h, 2, true)
        SetEntityVelocity(v, 0.0, 0.0, 0.0)
        pcall(SetVehicleHandbrake, v, true)
        a.lastVehPos = vector3(x, y, z)
        return
    end

    -- Geschwindigkeit entlang der Blickrichtung, nicht entlang der Bahn: die
    -- Bahnrichtung zittert (gerundete Positionen) und liesse den Wagen krabben.
    -- Betrag aus der Aufzeichnung, Richtung aus dem Heading.
    local dt  = (s2.relT or 0.0) - (s1.relT or 0.0)
    local dir = rotToDir(0.0, h)           -- Einheitsvektor vorwaerts
    local nx, ny = -dir.y, dir.x           -- Einheitsvektor nach links

    -- Betrag aus der Aufzeichnung; Vorzeichen aus der Fahrtrichtung, damit
    -- Rueckwaertsfahren nicht als Vorwaertsrollen erscheint.
    local sp = 0.5 * ((s1.speed or 0.0) + (s2.speed or 0.0))
    local tdx, tdy = (s2.x - s1.x), (s2.y - s1.y)
    if (tdx * dir.x + tdy * dir.y) < 0.0 then sp = -sp end

    -- Positionsfehler in laengs/quer zerlegen: laengs holt auf, quer zieht
    -- sanft zurueck auf die Linie.
    local alongErr = ex * dir.x + ey * dir.y
    local crossErr = ex * nx + ey * ny
    local aGain = cfgNum('DriveAlongGain', 1.5)
    local cGain = cfgNum('DriveCrossGain', 1.2)

    local spCmd = sp * rate + clamp(alongErr * aGain, -8.0, 8.0)
    local cross = (errH > soft) and (crossErr * cGain) or 0.0

    local vx = dir.x * spCmd + nx * cross
    local vy = dir.y * spCmd + ny * cross

    -- Hochachse: am Boden der Federung, in der Luft der Aufzeichnung. Zeigt die
    -- Aufzeichnung deutliche Senkrechtbewegung, war das Fahrzeug in der Luft ->
    -- vorgeben. Nachlauf, weil am Sprungscheitel vz durch null geht.
    local pv = GetEntityVelocity(v)
    local vz = pv.z

    local vzTrack = (dt > 0.001) and ((s2.z - s1.z) / dt * rate) or 0.0
    local airVz   = cfgNum('DriveAirborneVz', 2.0)
    local nowMs   = GetGameTimer()

    if math.abs(vzTrack) > airVz then
        a.airUntil = nowMs + math.floor(cfgNum('DriveAirborneHoldMs', 600))
    end
    if a.airUntil and nowMs < a.airUntil then
        vz = vzTrack
        -- In der Luft darf die Hoehe nachgeregelt werden (keine Federung).
        if errZ > soft then vz = vz + ez * gain end
    end

    -- Bremsen loesen, sonst steht der Wagen (Handbremse durch die Engine).
    pcall(SetVehicleHandbrake, v, false)
    pcall(SetVehicleBrakeLights, v, false)
    for i = 0, (a.wheelCount or 4) - 1 do
        pcall(SetVehicleWheelBrakePressure, v, i, 0.0)
    end

    -- Raeder ueber den Antriebspfad drehen (spCmd = Vorwaertsanteil, mit
    -- Vorzeichen): SetVehicleForwardSpeed schreibt auch die Raddrehzahl.
    pcall(SetVehicleForwardSpeed, v, spCmd)

    -- Danach die Bahn wieder vorgeben (ForwardSpeed setzt die Achsgeschwindigkeit
    -- mit; im Schleudern laege der Klon sonst daneben).
    SetEntityVelocity(v, vx, vy, vz)

    -- Nur die Hochachse; Neigung/Rollen gehoert der Physik (Bodenkontakt).
    SetEntityHeading(v, h)

    a.lastVehPos = vector3(cur.x, cur.y, cur.z)
end

local function spinWheels(a, veh, speedMs)
    if a.noWheelSpin then return end

    -- Vorzeichen: die Engine rechnet v = -w * r, Vorwaertsfahrt = negatives omega.
    a.wheelSpeedWant = speedMs
    for i = 0, (a.wheelCount or 4) - 1 do
        local omega = -speedMs / ((a.wheelRadius and a.wheelRadius[i]) or 0.35)
        if i == 0 then a.wheelWant = omega end
        local ok = pcall(SetVehicleWheelRotationSpeed, veh, i, omega + 0.0)
        if not ok then
            -- Faengt nur ein fehlendes Native ab.
            a.noWheelSpin = true
            return
        end
    end
end

-- ── Weltspur: Fahrzeuge ohne Insassen ──────────────────────────────────────
-- Eigener Pool, getrennt von den Akteursklonen: leer, kein Namensschild, zaehlt
-- nicht gegen den Akteursdeckel, kommt und geht nach Abstand zur Kamera.

local wveh   = {}      -- [key] = { ent, model }
local wvehN  = 0
local wSeen  = {}      -- wiederverwendet: Schluessel dieses Bildes
local wDup   = {}      -- wiederverwendet: Akteursfahrzeuge dieses Bildes

-- Abstand^2, unter dem Welt- und Akteursfahrzeug gleichen Modells als dasselbe
-- gelten (3 m deckt den Versatz zwischen zwei Abtastzeitpunkten).
local DUP_DIST2 = 9.0
-- Stellvertreter-Actor: traegt die badModels-Liste fuer alle Weltfahrzeuge.
local wStub  = { badModels = {} }

local function removeWorldVeh(key)
    local w = wveh[key]
    if not w then return end
    if w.ent and DoesEntityExist(w.ent) then
        SetEntityAsMissionEntity(w.ent, true, true)
        if w.isVeh then DeleteVehicle(w.ent) else DeletePed(w.ent) end
    end
    wveh[key] = nil
    wvehN = wvehN - 1
end

local function clearWorldVeh()
    for key in pairs(wveh) do removeWorldVeh(key) end
    wvehN = 0
end

local function maxWorldVeh()
    local v = tonumber(Config and Config.Playback and Config.Playback.MaxWorldVehicles)
    if v and v >= 0 then return math.floor(v) end
    return 20
end

--- Ein Weltfahrzeug bereitstellen, oder nil (Modell fehlt / Pool erschoepft).
local function ensureWorldVeh(key, model, isVeh, x, y, z, h)
    local w = wveh[key]
    if w and w.model == model and w.isVeh == isVeh
       and w.ent and DoesEntityExist(w.ent) then return w end
    if w then removeWorldVeh(key) end
    if wStub.badModels[model] then return nil end

    -- Weltfussgaenger: Umgebung, kein Namensschild.
    if not isVeh then
        local myGen = sessionGen
        if not loadModel(wStub, model, false) then return nil end
        if sessionGen ~= myGen or not active then return nil end

        local ped = CreatePed(4, model, x, y, z, h or 0.0, false, false)
        SetModelAsNoLongerNeeded(model)
        if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetPedCanPlayAmbientAnims(ped, false)
        SetEntityCollision(ped, false, false)
        FreezeEntityPosition(ped, true)

        w = { ent = ped, model = model, isVeh = false }
        wveh[key] = w
        wvehN = wvehN + 1
        return w
    end

    -- loadModel gibt beim Streamen ab; danach Sitzung pruefen.
    local myGen = sessionGen
    if not loadModel(wStub, model, true) then return nil end
    if sessionGen ~= myGen or not active then return nil end

    local ent = CreateVehicle(model, x, y, z, h or 0.0, false, false)
    SetModelAsNoLongerNeeded(model)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end

    SetEntityInvincible(ent, true)
    SetVehicleDoorsLocked(ent, 4)
    SetVehicleCanBeVisiblyDamaged(ent, false)
    SetVehicleEngineOn(ent, false, true, true)
    -- Ganz aus der Physikwelt: wird jedes Bild gesetzt, darf die Klone nicht anstossen.
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)

    w = { ent = ent, model = model, isVeh = true }
    wveh[key] = w
    wvehN = wvehN + 1
    return w
end

--- Die Umgebung dieses Bildes stellen. Auswahl nach Abstand zur Kamera;
--- was herausfaellt, wird abgeraeumt (sonst Geisterwagen im naechsten Schwenk).
local function updateWorldVehicles(t, origin)
    if not (World and World.Snapshot) or not origin then return end
    local cap = maxWorldVeh()
    if cap == 0 or (Config.World and Config.World.Vehicles == false) then
        if wvehN > 0 then clearWorldVeh() end
        return
    end

    local n = World.Snapshot(segTime(t), origin.x, origin.y, origin.z, cap)

    for k in pairs(wSeen) do wSeen[k] = nil end

    -- Entdopplung gegen den Beweisstrom: beim Ein-/Aussteigen kann ein Fahrzeug
    -- kurz in beiden Spuren stehen. Verglichen wird Modell UND Ort (baugleiche
    -- Wagen nebeneinander sind normal).
    local nDup = 0
    for i = 1, #actors do
        local a = actors[i]
        local v = a.cloneVeh
        if v and DoesEntityExist(v) then
            nDup = nDup + 1
            local c = GetEntityCoords(v)
            local d = wDup[nDup]
            if not d then d = {}; wDup[nDup] = d end
            d.model = a.curVehModel or 0
            d.x, d.y, d.z = c.x, c.y, c.z
        end
    end

    for i = 1, n do
        local e = World.Get(i)
        -- Ein Ped, der im Fahrzeug sass, wird nicht als stehende Gestalt gebaut
        -- (seine Position ist die des Fahrzeugs).
        local inVehPed = e and e.isVeh == false
                         and ((e.flags or 0) & Protocol.FLAG.IN_VEHICLE) ~= 0

        if e and e.model and e.model ~= 0 and not inVehPed then
            local isVeh = e.isVeh ~= false

            -- Entdoppelt wird nur gegen die Fahrzeuge der Beteiligten.
            local dup = false
            if isVeh then
                for k = 1, nDup do
                    local d = wDup[k]
                    if d.model == e.model then
                        local dx, dy, dz = d.x - e.x, d.y - e.y, d.z - e.z
                        if (dx * dx + dy * dy + dz * dz) < DUP_DIST2 then dup = true; break end
                    end
                end
            end

            if not dup then
                local w = ensureWorldVeh(e.key, e.model, isVeh, e.x, e.y, e.z, e.h)
                if w then
                    SetEntityCoordsNoOffset(w.ent, e.x, e.y, e.z, false, false, false)
                    if isVeh then
                        SetEntityRotation(w.ent, e.pitch or 0.0, e.roll or 0.0, e.h or 0.0, 2, true)
                    else
                        -- Fussgaenger steht aufrecht: nur Heading, keine Neigung.
                        SetEntityHeading(w.ent, e.h or 0.0)
                    end
                    wSeen[e.key] = true
                end
            end
        end
    end

    -- Entfernen waehrend des pairs-Durchlaufs ist zulaessig, Anlegen nicht.
    for key in pairs(wveh) do
        if not wSeen[key] then removeWorldVeh(key) end
    end
end

-- ── Klone: anlegen, abraeumen, abdunkeln ───────────────────────────────────

local function removeActorClone(a)
    removeVehicle(a)
    if a.clonePed and DoesEntityExist(a.clonePed) then
        SetEntityAsMissionEntity(a.clonePed, true, true)
        DeletePed(a.clonePed)
    end
    a.clonePed  = nil
    a.inVeh     = false
    a.dead      = false
    a.seatDead  = false
    a.hidden    = false
    a.warp      = false
    a.alphaPed  = nil
    a.lastMotion, a.lastWeapon = nil, nil
    a.lastBlend, a.lastTaskAt  = -1, 0
end

--- Tod eines Klons, der im Fahrzeug sitzt. Bewusst nicht ueber SetPedToRagdoll
--- (wuerde den Koerper aus dem Sitz werfen), sondern echte Health 0 — die
--- Engine setzt daraufhin selbst die Sitzhaltung eines Toten.
local function setSeatedDeath(a, downed)
    local ped = a.clonePed
    if not ped or not DoesEntityExist(ped) then return end
    if downed then
        if not a.seatDead then
            a.seatDead = true
            a.dead = false   -- a.dead fuehrt die Zu-Fuss-Haltung; im Sitz nicht
            -- Unverwundbarkeit fuer den aufgezeichneten Tod kurz aufheben.
            SetEntityInvincible(ped, false)
            SetEntityHealth(ped, 0)
        end
    elseif a.seatDead then
        a.seatDead = false
        a.dead     = false
        if IsPedDeadOrDying(ped, true) then ResurrectPed(ped) end
        SetEntityInvincible(ped, true)
        -- Nur ausserhalb eines Fahrzeugs: im Sitz raeumte ClearPedTasksImmediately
        -- die haltende Task weg, der Klon fiele auf die Strasse.
        if not IsPedInAnyVehicle(ped, false) then ClearPedTasksImmediately(ped) end
    end
end

local function cloneCount()
    local n = 0
    for i = 1, #actors do
        if actors[i].clonePed then n = n + 1 end
    end
    return n
end

--- Obergrenze gleichzeitiger Klone. Ohne Config-Eintrag der Akteursdeckel
--- des Manifests.
local function maxClones()
    local v = tonumber((Config and Config.Playback and Config.Playback.MaxClones)
                       or (Config and Config.MaxClones))
    if v and v >= 1 then return math.floor(v) end
    local m = Segments.Manifest()
    local n = m and tonumber(m.maxActors)
    return (n and n >= 1) and math.floor(n) or 12
end

--- Den unwichtigsten Klon abraeumen, um Platz zu schaffen. Wichtigkeit =
--- Abstand zum verfolgten Spieler (ein Vorfall spielt an einem Ort), ohne
--- Bezugspunkt der aelteste.
local function freeCloneSlot(keep)
    local fa = actors[focusIdx]
    local ref = lastTargetPos
    local worst, worstScore
    for i = 1, #actors do
        local a = actors[i]
        if a ~= keep and a ~= fa and a.clonePed and DoesEntityExist(a.clonePed) then
            local score
            if ref then
                score = #(GetEntityCoords(a.clonePed) - ref)
            else
                score = -(a.dataAt or 0)   -- ohne Bezugspunkt: aeltester zuerst
            end
            if not worstScore or score > worstScore then worst, worstScore = a, score end
        end
    end
    if not worst then return false end
    removeActorClone(worst)
    return true
end

--- Klon anlegen, erst an einer Stelle mit echten Daten.
local function spawnActorPed(a, x, y, z, h)
    local myGen = sessionGen
    local model = (a.appearance and a.appearance.model) or a.model
    -- Faellt das Modell aus, Freemode-Rueckfall: falsches Aussehen > kein Klon.
    if not loadModel(a, model, false) then
        model = GetHashKey('mp_m_freemode_01')
        if not loadModel(a, model, false) then return end
    end
    -- loadModel gibt ab; danach Sitzung pruefen.
    if sessionGen ~= myGen then return end

    a.clonePed = CreatePed(4, model, x, y, z, h, false, false)
    SetModelAsNoLongerNeeded(model)
    if not a.clonePed or a.clonePed == 0 or not DoesEntityExist(a.clonePed) then
        -- Ped-Pool erschoepft. Kein badModels-Eintrag, naechster Frame versucht erneut.
        a.clonePed = nil
        return
    end

    SetEntityInvincible(a.clonePed, true)
    SetBlockingOfNonTemporaryEvents(a.clonePed, true)
    SetPedCanRagdoll(a.clonePed, true)
    SetPedCanPlayAmbientAnims(a.clonePed, false)
    -- Kollision AN, damit die Lokomotion sauber auf dem Boden aufsetzt.
    SetEntityCollision(a.clonePed, Config.Playback.Locomotion, false)
    applyAppearance(a.clonePed, a.appearance)
    a.alphaPed = nil
end

--- Welche Quelle die Umgebung liefert (Config.Playback.Source).
local function sourceMode()
    local m = Config and Config.Playback and Config.Playback.Source
    if m == 'client' or m == 'both' then return m end
    return 'server'
end

local function ensureClone(a, x, y, z, h)
    -- Reine Clientsicht: keine Klone aus dem Beweisstrom (sonst jeder doppelt).
    if sourceMode() == 'client' then
        if a.clonePed then removeActorClone(a) end
        return nil
    end

    if a.clonePed and DoesEntityExist(a.clonePed) then return a.clonePed end
    if a.clonePed then removeActorClone(a) end

    -- Deckel erreicht: der entfernteste Klon weicht, nicht der neue Anwaerter.
    if cloneCount() >= maxClones() then
        if not freeCloneSlot(a) then return nil end
    end
    spawnActorPed(a, x, y, z, h)
    return a.clonePed
end

--- Deckkraft setzen (nur bei Aenderung). 'stale' abgedunkelt, 'ok' voll —
--- trennt "laedt noch" von "war nicht da" (unsichtbar).
local function setAlpha(a, want)
    local ped = a.clonePed
    if ped and DoesEntityExist(ped) and a.alphaPed ~= want then
        a.alphaPed = want
        if want >= 255 then pcall(ResetEntityAlpha, ped)
        else SetEntityAlpha(ped, want, false) end
    end
    local veh = a.cloneVeh
    if veh and DoesEntityExist(veh) and (a.alphaVeh ~= want or a.alphaEnt ~= veh) then
        a.alphaVeh, a.alphaEnt = want, veh
        if want >= 255 then pcall(ResetEntityAlpha, veh)
        else SetEntityAlpha(veh, want, false) end
    end
end

-- ── Aufbau / Abbau ─────────────────────────────────────────────────────────

local function closeNui()
    SendNUIMessage({ action = 'close' })
    if cursorMode then setCursor(false) end
end

--- Alles abraeumen. keepStream=true beim Wechsel auf ein neues Manifest: der
--- Cache hat es bereits uebernommen, Bye/Reset wuerde die neue Sitzung wegwerfen.
local function teardown(keepStream)
    active = false
    RenderScriptCams(false, false, 0, true, false)
    if cam then DestroyCam(cam, false); cam = nil end
    sessionGen = sessionGen + 1
    for _, a in ipairs(actors) do removeActorClone(a) end
    actors = {}
    -- Weltfahrzeuge haengen an keinem Actor; sonst blieben sie in der Welt stehen.
    clearWorldVeh()
    local p = PlayerPedId()
    FreezeEntityPosition(p, false)
    SetEntityVisible(p, true, false)
    SetEntityInvincible(p, false)
    ClearFocus()                      -- Streaming wieder an den eigenen Ped binden
    if Config.Playback.RestoreWorldState then
        NetworkClearClockTimeOverride()
        ClearOverrideWeather()
    end
    if not keepStream then
        -- Bye gibt die Serversitzung frei, Reset raeumt den Cache.
        Segments.Bye()
        Segments.Reset()
    end
    closeNui()
end

--- Akteure aus dem Manifest anlegen. Keine Klone (die entstehen faul).
local function buildActors(m)
    actors = {}; focusIdx = 1
    sessionGen = sessionGen + 1

    local base = Segments.T0 or 0
    -- Zeitachse aus dem Manifest, nicht aus dem kleinsten geladenen Zeitstempel:
    -- nachgeladene Segmente verschoeben sonst rueckwirkend den Nullpunkt.
    timeBase = (tonumber(m.epoch) or 0) + base
    duration = math.max(0.0, (Segments.T1 or 0) - base)

    local list = Segments.Players()
    for i = 1, #list do
        local p = list[i]
        actors[i] = {
            p = p, hash = p.hash, id = p.id, name = p.name,
            online = p.online ~= false,
            model = p.model, appearance = p.appearance,
            gen = sessionGen,
            -- Schreibtische fuer die Darstellung (fillEv/fillFid).
            s1 = {}, s2 = {}, fs = {},
            clonePed = nil, cloneVeh = nil, curVehModel = 0,
            dead = false, lastBlend = -1, lastTaskAt = 0, lastMotion = nil,
            state = 'stale', dataAt = 0,
        }
        if m.focusHash and p.hash == m.focusHash then focusIdx = i end
    end
    if #actors == 0 then return false end

    -- Meldungen auf die Zeitachse legen. Meldungen und Hinweise zaehlen server-
    -- seitig getrennt ab 1; jeder Eintrag bekommt einen Praefix-Schluessel.
    incidents = {}
    for _, tk in ipairs(m.tickets or {}) do
        local rel = (tonumber(tk.t) or 0) - timeBase
        if rel >= -5 and rel <= duration + 5 then
            tk.relT = clamp(rel, 0, duration)
            tk.status = tk.status or 'open'
            tk.key = 't' .. tostring(tk.id)
            incidents[#incidents + 1] = tk
        end
    end
    -- Automatische Hinweise, falls der Betreiber sie eingeschaltet hat.
    for _, inc in ipairs(m.incidents or {}) do
        local rel = (tonumber(inc.t) or 0) - timeBase
        if rel >= -5 and rel <= duration + 5 then
            inc.relT = clamp(rel, 0, duration)
            inc.status = inc.status or 'open'
            inc.auto = true
            inc.key = 'i' .. tostring(inc.id)
            incidents[#incidents + 1] = inc
        end
    end
    table.sort(incidents, function(a, b) return a.relT < b.relT end)

    -- Schadensereignisse ebenfalls auf die Zeitachse legen
    damageEvents = {}
    for _, ev in ipairs(m.damage or {}) do
        local rel = (tonumber(ev.t) or 0) - timeBase
        if rel >= 0 and rel <= duration then
            damageEvents[#damageEvents + 1] =
                { relT = rel, shooter = ev.shooter, victim = ev.victim }
        end
    end

    worldLog = m.world or {}
    adminName = m.me or '?'
    return true
end

-- ── Welt-Zustand (Uhrzeit/Wetter) ──────────────────────────────────────────

-- Klartext-Bezeichnung der gaengigen Wetterlagen fuer die Kontextzeile.
WEATHER_LABEL = {
    [GetHashKey('CLEAR')] = 'KLAR',         [GetHashKey('EXTRASUNNY')] = 'KLAR',
    [GetHashKey('CLOUDS')] = 'BEWOELKT',   [GetHashKey('OVERCAST')] = 'BEDECKT',
    [GetHashKey('RAIN')] = 'REGEN',        [GetHashKey('CLEARING')] = 'AUFKLAREND',
    [GetHashKey('THUNDER')] = 'GEWITTER',  [GetHashKey('SMOG')] = 'SMOG',
    [GetHashKey('FOGGY')] = 'NEBEL',       [GetHashKey('XMAS')] = 'SCHNEE',
    [GetHashKey('SNOW')] = 'SCHNEE',       [GetHashKey('SNOWLIGHT')] = 'SCHNEE',
    [GetHashKey('BLIZZARD')] = 'BLIZZARD', [GetHashKey('HALLOWEEN')] = 'HALLOWEEN',
    [GetHashKey('NEUTRAL')] = 'NEUTRAL',
}

local lastWorldIdx = -1
local function applyWorldState()
    if not Config.Playback.RestoreWorldState or #worldLog == 0 then return end
    local absT = timeBase + playT
    local best, bestIdx = nil, -1
    for i, w in ipairs(worldLog) do
        if w.t <= absT + 5 then best, bestIdx = w, i else break end
    end
    best = best or worldLog[1]
    if bestIdx == lastWorldIdx then return end
    lastWorldIdx = bestIdx
    NetworkOverrideClockTime(best.h or 12, best.m or 0, best.s or 0)
    if best.w1 and best.w2 then
        SetWeatherTypeTransition(best.w1, best.w2, best.pct or 0.0)
    end
    sceneClockLabel = ('%02d:%02d'):format(best.h or 0, best.m or 0)
    sceneWeatherLabel = WEATHER_LABEL[best.w1] or '—'
end

-- ── Lokomotion: Peds ueber die Engine laufen lassen ────────────────────────

local function drivePed(a, s1, s2, f, x, y, z, h, now)
    local ped = a.clonePed

    -- Pausieren/Scrubben: exakt positionieren, ohne KI.
    if not playing or scrubbing or playDir < 0 or not Config.Playback.Locomotion then
        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
        SetEntityHeading(ped, h)
        a.lastTaskAt = 0
        return
    end

    -- Lauf: Geschwindigkeit aus den Samples, Engine spielt die Lokomotion.
    local dt   = s2.relT - s1.relT
    local dist = #(vector3(s2.x, s2.y, s2.z) - vector3(s1.x, s1.y, s1.z))
    local spd  = (dt > 0.001) and (dist / dt) or 0.0

    local blend = 0.0
    if spd >= 0.4 and spd < 2.2 then blend = 1.0
    elseif spd >= 2.2 and spd < 4.6 then blend = 2.0
    elseif spd >= 4.6 then blend = 3.0 end

    if blend ~= a.lastBlend then
        SetPedDesiredMoveBlendRatio(ped, blend)
        a.lastBlend = blend
    end

    -- Task regelmaessig erneuern, damit der Ped dem naechsten Sample zulaeuft.
    if (now - a.lastTaskAt) > 250 then
        a.lastTaskAt = now
        if blend > 0.0 then
            TaskGoStraightToCoord(ped, s2.x, s2.y, s2.z, math.max(spd, 1.0), 2000, s2.heading, 0.0)
        else
            ClearPedTasks(ped)
            SetEntityHeading(ped, h)
        end
    end

    -- Drift-Korrektur: laeuft der Klon aus dem Ruder, hart nachsetzen.
    local cur = GetEntityCoords(ped)
    if #(cur - vector3(x, y, z)) > Config.Playback.DriftCorrection then
        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
        SetEntityHeading(ped, h)
        a.lastTaskAt = 0
    end
end

-- ── Namensschilder ─────────────────────────────────────────────────────────

--- Namensschild mit Health/Weste-Balken ueber dem Klon.
local function drawNameTag(pos, a, s1, fs, isFocus)
    local ok, sx, sy = World3dToScreen2d(pos.x, pos.y, pos.z + 1.15)
    if not ok then return end

    local dist = #(camPos - pos)
    if dist > 120.0 then return end                    -- weit weg nicht zeichnen
    local scale = clamp(1.0 - (dist / 160.0), 0.45, 1.0)

    -- Name mit vorangestellter Server-ID (Ausgeloggte haben keine -> Name allein).
    if Config.Playback.ShowNameTags then
        local label = a.id and ('[%d] %s'):format(a.id, a.name) or a.name
        SetTextFont(4); SetTextScale(0.0, 0.34 * scale); SetTextCentre(true)
        if isFocus then SetTextColour(120, 200, 255, 240) else SetTextColour(235, 235, 235, 190) end
        SetTextOutline()
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(label)
        EndTextCommandDisplayText(sx, sy)
    end

    if not Config.Playback.ShowStatusBars then return end

    -- Balken darunter. GTA-Health laeuft von 100 (tot) bis 200 (voll).
    local hp   = clamp(((s1.health or 200) - 100) / 100.0, 0.0, 1.0)
    local arm  = clamp((s1.armour or 0) / 100.0, 0.0, 1.0)
    local w    = 0.042 * scale
    local h    = 0.0042 * scale
    local yBar = sy + 0.024 * scale

    local function bar(y, frac, r, g, b)
        DrawRect(sx, y, w, h, 0, 0, 0, 170)                     -- Untergrund
        if frac > 0.001 then
            DrawRect(sx - w / 2 + (w * frac) / 2, y, w * frac, h, r, g, b, 225)
        end
    end

    -- Health: gruen, ab einem Drittel gelb, im kritischen Bereich rot.
    if hp > 0.66      then bar(yBar, hp, 48, 209, 88)
    elseif hp > 0.33  then bar(yBar, hp, 255, 214, 10)
    else                   bar(yBar, hp, 255, 69, 58) end

    if arm > 0.001 then bar(yBar + h + 0.0022 * scale, arm, 10, 132, 255) end

    -- Keine Zahlenwerte unter den Balken; die genauen Werte stehen in der Liste.
end

-- ── Telemetrie und Ereignisse fuer das Datenband ───────────────────────────
-- Aus den dekodierten Zustaenden abgeleitet, nur ueber das residente Fenster
-- (Config.ClientCacheSeconds); waechst mit dem Geladenen.

--- Luecken fuers Band, aus der Anwesenheit des Manifests (nicht aus dem
--- geladenen Fenster: noch nicht geladen ist keine Abwesenheit).
local function buildGaps(a)
    local out = {}
    local p = a.p
    -- Belegung unbekannt: keine Abwesenheit gezeichnet.
    if not p or p.barsUnknown then return out end

    local sp = {}
    for _, s in ipairs(p.spans or {}) do
        local f = clamp((tonumber(s.from) or 0) - timeBase, 0, duration)
        local t = clamp((tonumber(s.to)   or 0) - timeBase, 0, duration)
        if t > f then sp[#sp + 1] = { from = f, to = t } end
    end
    if #sp == 0 then return out end
    table.sort(sp, function(x, y) return x.from < y.from end)

    local cur = 0.0
    for _, s in ipairs(sp) do
        if s.from - cur > GAP_SECONDS then out[#out + 1] = { from = cur, to = s.from } end
        if s.to > cur then cur = s.to end
    end
    if duration - cur > GAP_SECONDS then out[#out + 1] = { from = cur, to = duration } end
    return out
end

local function buildTelemetry(a)
    local gaps = buildGaps(a)
    local p = a.p
    local n = p and p.n or 0
    if n == 0 then return {}, {}, gaps end

    local T, HP, SP, FL = p.sT, p.sHealth, p.sSpeed, p.sFlags
    local base = Segments.T0 or 0
    local series, events = {}, {}
    local stride = math.max(1, math.floor(n / 600))

    for i = 1, n, stride do
        series[#series + 1] = {
            t = T[i] - base,
            speed = SP[i] or 0.0,
            health = HP[i] or 0,
            -- alive unterbricht die Health-Kurve im Tod statt sie abstuerzen zu lassen.
            alive = ((FL[i] or 0) & Protocol.FLAG.ALIVE) ~= 0,
        }
    end

    -- Ereignisse aus Zustandswechseln: Tod, Wiederbelebung, Fahrzeugwechsel
    local VM = p.sVehModel
    for i = 2, n do
        local wasAlive = ((FL[i - 1] or 0) & Protocol.FLAG.ALIVE) ~= 0
        local isAlive  = ((FL[i]     or 0) & Protocol.FLAG.ALIVE) ~= 0
        local t = T[i] - base
        if wasAlive and not isAlive then
            events[#events + 1] = { t = t, kind = 'death' }
        elseif isAlive and not wasAlive then
            events[#events + 1] = { t = t, kind = 'spawn' }
        end
        if (VM[i] or 0) ~= (VM[i - 1] or 0) then
            events[#events + 1] = { t = t, kind = 'vehicle' }
        end
    end

    -- Schadensereignisse des Servers, sofern sie diesen Spieler betreffen
    for _, ev in ipairs(damageEvents) do
        if ev.shooter == a.id or ev.victim == a.id then
            events[#events + 1] = { t = ev.relT, kind = 'damage' }
        end
    end

    return series, events, gaps
end

-- ── NUI ────────────────────────────────────────────────────────────────────

local telPushAt, telWinLo, telWinHi = 0, nil, nil

local function nuiSendTelemetry()
    local a = actors[focusIdx]
    if not a then return end
    local series, events, gaps = buildTelemetry(a)
    telPushAt = GetGameTimer()
    telWinLo, telWinHi = Segments.Window()
    SendNUIMessage({ action = 'telemetry', series = series, events = events, gaps = gaps })
end

--- Die Kurve nachfuehren, sobald sich das residente Fenster verschoben hat.
local function nuiTelemetryTick(now)
    if now - telPushAt < 1000 then return end
    local lo, hi = Segments.Window()
    if lo == telWinLo and hi == telWinHi then telPushAt = now; return end
    nuiSendTelemetry()
end

--- Anwesenheitsspanne eines Spielers auf der Replay-Zeitachse.
local function actorSpan(a)
    local from, to
    for _, s in ipairs((a.p and a.p.spans) or {}) do
        local f = (tonumber(s.from) or 0) - timeBase
        local t = (tonumber(s.to)   or 0) - timeBase
        if not from or f < from then from = f end
        if not to   or t > to   then to   = t end
    end
    return clamp(from or 0, 0, duration), clamp(to or duration, 0, duration)
end

local function nuiOpen(jumpTo)
    local list = {}
    for i, a in ipairs(actors) do
        local from, to = actorSpan(a)
        list[i] = {
            idx = i, id = a.id, name = a.name,
            online = a.online ~= false,   -- Ausgeloggte haben keine Server-ID mehr
            from = from, to = to,
            -- Health/Fahrzeug fuellt die laufende Wiedergabe nach (beim Oeffnen
            -- noch nichts geladen, nichts raten).
            health = nil, veh = false,
        }
    end

    local series, events, gaps = buildTelemetry(actors[focusIdx])
    telPushAt = GetGameTimer()
    telWinLo, telWinHi = Segments.Window()

    SendNUIMessage({
        action    = 'open',
        locale    = Config.Locale or 'de',
        duration  = duration,
        actors    = list,
        focusIdx  = focusIdx,
        incidents = incidents,
        events    = events,
        telemetry = series,
        gaps      = gaps,
        -- Clientseitig kein os: Datum/Uhrzeit formatiert die Oberflaeche.
        startedAt = timeBase,
        endedAt   = timeBase + math.floor(duration),
        activeIncident = activeIncidentId,
        me        = adminName,
        jumpTo    = jumpTo,
    })
end

local lastNuiPush = 0
local function nuiState(now)
    if now - lastNuiPush < 100 then return end
    lastNuiPush = now

    local pos = lastTargetPos
    SendNUIMessage({
        action = 'state',
        t = playT, playing = playing, rate = speed,
        focusIdx = focusIdx, follow = followMode, cursor = cursorMode,
        activeIncident = activeIncidentId,
        scrub = scrubbing or not playing,
        -- Puffern ist ein eigener Zustand: laeuft, aber Zeit steht (Material fehlt).
        buffering = buffering,
        pos = pos and ('%.1f  %.1f  %.1f'):format(pos.x, pos.y, pos.z) or '—',
        clock = sceneClockLabel,
        weather = sceneWeatherLabel,
    })
end

--- Zeiger ein-/ausschalten. Eine Stelle fuer alle Aufrufer.
function setCursor(on)
    cursorMode = on and true or false
    SetNuiFocus(cursorMode, cursorMode)
    -- Kein KeepInput: sonst bekaeme das Spiel die Maustasten mit -> flackernde Klicks.
    SetNuiFocusKeepInput(false)
end

--- Zeiger umschalten mit Sperre. Escape wird an→aus von Oberflaeche und Spiel
--- gelesen; ohne Sperre sieht das Spiel denselben Druck erneut und schaltet
--- sofort wieder an (man haengt im Zeigermodus fest).
local cursorLockUntil = 0
function RPSToggleCursor()
    local now = GetGameTimer()
    if now < cursorLockUntil then return end
    cursorLockUntil = now + 350
    setCursor(not cursorMode)
end

--- Abtastzustand eines Actors nach einem Zeitsprung zuruecksetzen (der zuletzt
--- gesetzte Sollpunkt ist dann wertlos). Suchzeiger fuehrt der Cache selbst.
local function resetActorScan(a)
    a.lastTaskAt = 0
    a.lastVehPos = nil; a.posLead = nil
    -- Nach einem Sprung hart setzen statt zulaufen.
    a.warp = true
end

local function seekTo(t)
    playT = clamp(t, 0, duration)
    for _, a in ipairs(actors) do resetActorScan(a) end
    scrubbing = true
    scrubUntil = GetGameTimer() + 400
    -- Nach einem Sprung puffern, bevor es weiterlaeuft: der neue Zeitpunkt liegt
    -- in einem anderen Abschnitt, sofortiges Weiterlaufen stottert.
    seekHold   = true
    seekHoldTo = GetGameTimer() + SEEK_HOLD_MAX_MS
end


RegisterNUICallback('playpause', function(_, cb) playing = not playing; cb('ok') end)
RegisterNUICallback('seek', function(d, cb) seekTo(tonumber(d.t) or 0); cb('ok') end)
RegisterNUICallback('rate', function(d, cb)
    speed = clamp(tonumber(d.v) or 1.0, 0.1, 8.0); playDir = 1; cb('ok')
end)
RegisterNUICallback('shuttle', function(d, cb)
    local dir = tonumber(d.dir) or 0
    if dir == 0 then playDir = 1; speed = 1.0; playing = false
    else playDir = dir; speed = clamp(tonumber(d.rate) or 2.0, 0.1, 8.0); playing = true end
    cb('ok')
end)
RegisterNUICallback('step', function(d, cb)
    -- Frame-Step: ein Sample vor oder zurueck
    playing = false
    local dir = tonumber(d.dir) or 1
    seekTo(playT + dir * 0.05)
    cb('ok')
end)
RegisterNUICallback('focus', function(d, cb)
    local i = tonumber(d.idx)
    if i and actors[i] then focusIdx = i; nuiSendTelemetry() end
    cb('ok')
end)
RegisterNUICallback('camera', function(d, cb)
    if d and d.follow ~= nil then followMode = d.follow and true or false
    else followMode = not followMode end

    -- Kameramodus unabhaengig vom Zeiger; der Zeiger nur mit Escape.
    cb('ok')
end)
RegisterNUICallback('incidentFocus', function(d, cb)
    activeIncidentId = d and d.key and tostring(d.key) or nil
    -- Kamera auf die betroffene Person: Meldung -> Melder, Hinweis -> Opfer.
    for _, inc in ipairs(incidents) do
        if inc.key == activeIncidentId then
            local wantHash = inc.reporterHash
            local want     = inc.reporterId or inc.victim or inc.shooter
            for i, a in ipairs(actors) do
                if (wantHash and a.hash == wantHash) or (want and a.id == want) then
                    focusIdx = i; nuiSendTelemetry(); break
                end
            end
            break
        end
    end
    cb('ok')
end)

--- Status einer Meldung aendern (offen / in Arbeit / erledigt).
RegisterNUICallback('ticketStatus', function(d, cb)
    local key, status = d and d.key and tostring(d.key) or nil, tostring(d.status or '')
    if key then
        for _, inc in ipairs(incidents) do
            if inc.key == key then
                inc.status = status
                -- An den Server geht die reine Nummer (getrennte Listen).
                if not inc.auto then TriggerServerEvent('d-rps:ticketStatus', inc.id, status) end
                break
            end
        end
    end
    cb('ok')
end)
--- Anzeige-Einstellungen aus der Oberflaeche (nur die 3D-Szene).
RegisterNUICallback('view', function(d, cb)
    if d then
        if d.nametags   ~= nil then Config.Playback.ShowNameTags   = d.nametags and true or false end
        if d.statusbars ~= nil then Config.Playback.ShowStatusBars = d.statusbars and true or false end
    end
    cb('ok')
end)

--- In-/Out-Punkte der Export-Auswahl; vorgemerkt fuer den Beweisexport.
local exportIn, exportOut = nil, nil
RegisterNUICallback('inOut', function(d, cb)
    exportIn  = tonumber(d and d['in'])
    exportOut = tonumber(d and d.out)
    cb('ok')
end)

--- Sprungmarke setzen. Noch ohne Persistenz (kommt mit dem Beweisexport).
RegisterNUICallback('marker', function(_, cb) cb('ok') end)

--- Beweisexport. Reserviert: Aufruf angenommen, Kodierung folgt.
RegisterNUICallback('export', function(_, cb) cb('ok') end)

RegisterNUICallback('close', function(_, cb) teardown(false); cb('ok') end)
RegisterNUICallback('cursor', function(_, cb)
    RPSToggleCursor()
    cb('ok')
end)

-- ── Start ──────────────────────────────────────────────────────────────────

-- Sperre gegen ein zweites Laden (zwei schnelle /replay zoegen sich sonst die
-- Akteursliste unter den Fuessen weg).
local loading = false

--- Ein live nachgereichtes Aussehen uebernehmen (Reporter sendet erst kurz nach
--- dem Start) und den bereits stehenden Klon sofort umziehen.
RegisterNetEvent('d-rps:appearance', function(hash, appearance)
    if type(appearance) ~= 'table' then return end
    local h = tonumber(hash)
    if not h then return end
    h = math.floor(h) & 0xFFFFFFFF

    for _, a in ipairs(actors) do
        if a.hash == h then
            local oldModel = a.appearance and a.appearance.model or a.model
            a.appearance = appearance
            if appearance.model then a.model = appearance.model end

            if a.clonePed and DoesEntityExist(a.clonePed) then
                if appearance.model and appearance.model ~= oldModel then
                    -- Anderes Ped-Modell: Umziehen genuegt nicht, Neuaufbau.
                    removeActorClone(a)
                else
                    applyAppearance(a.clonePed, appearance)
                end
            end
            break
        end
    end
end)

RegisterNetEvent('d-rps:seg:manifest', function(m)
    if loading then return end
    loading = true

    -- client/segments.lua haengt am selben Ereignis und laeuft zuerst; hier nur
    -- pruefen, ob der Cache dasselbe Manifest uebernommen hat (sonst keine Zeitachse).
    if Segments.Manifest() ~= m then
        loading = false
        TriggerEvent('chat:addMessage',
            { args = { '^1[D-RPS]', 'Manifest unbrauchbar — Replay nicht geoeffnet' } })
        return
    end

    -- Den Stream NICHT freigeben: er gehoert bereits zur neuen Sitzung.
    if active then teardown(true) end

    if not buildActors(m) then
        loading = false
        -- Serversitzung ist bereits angelegt; ohne Bye liefe der Cache weiter.
        Segments.Bye()
        TriggerEvent('chat:addMessage', { args = { '^1[D-RPS]', 'Replay leer' } })
        return
    end

    -- Ab hier gilt das Replay als aktiv (teardown raeumt alles wieder ab).
    active = true

    local p = PlayerPedId()
    FreezeEntityPosition(p, true)
    SetEntityVisible(p, false, false)
    SetEntityInvincible(p, true)

    -- Startzeitpunkt. jumpSeg ist der Segmentanfang und immer vorhanden;
    -- jumpSec ist die genaue Sekunde einer Meldung und geht vor.
    local segSec  = tonumber(m.segSec) or 30
    local jumpSeg = tonumber(m.jumpSeg)
    playT = jumpSeg and clamp(jumpSeg * segSec - (Segments.T0 or 0), 0, duration) or 0.0

    activeIncidentId = nil
    local jumpSec = tonumber(m.jumpSec)
    if jumpSec then
        -- 10 s Vorlauf: der Vorfall beginnt vor dem Meldezeitpunkt.
        playT = clamp(jumpSec - timeBase - 10.0, 0, duration)
    end
    if m.ticketId then
        local key = 't' .. tostring(m.ticketId)
        for _, inc in ipairs(incidents) do
            if inc.key == key then activeIncidentId = key; break end
        end
    end

    -- Kamera beginnt beim Zuschauer (noch keine Spielerposition geladen) und
    -- rueckt nach, sobald das erste Sample da ist.
    followMode = true
    lastTargetPos = nil
    orbitYaw = GetEntityHeading(p) or 0.0; orbitPitch = 18.0; orbitDist = 6.0
    local me = GetEntityCoords(p)
    local rp = math.rad(orbitPitch); local horiz = orbitDist * math.cos(rp)
    local back = rotToDir(0.0, orbitYaw)
    camPos = vector3(me.x - back.x * horiz, me.y - back.y * horiz,
                     me.z + orbitDist * math.sin(rp) + 0.4)
    camYaw, camPitch = aimAt(camPos, vector3(me.x, me.y, me.z + 0.4))

    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
    SetCamRot(cam, camPitch, 0.0, camYaw, 2)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, false)

    playing = true; speed = 1.0; playDir = 1; lastWorldIdx = -1
    buffering = false
    for _, a in ipairs(actors) do resetActorScan(a) end
    loading = false

    -- Zuschau-first: Zeiger beim Oeffnen AUS, sofort bedienbar. Panels ueber Escape.
    setCursor(false)
    -- Letzte Anschlaege des getippten Befehls nicht als Kuerzel durchschlagen lassen.
    chatBlockUntil = GetGameTimer() + 600

    nuiOpen(playT)
end)

-- ── Playback-Loop ──────────────────────────────────────────────────────────

CreateThread(function()
    local last = GetGameTimer()
    while true do
        Wait(0)

        -- Ganz vorn: der Cache dekodiert gegen ein Zeitbudget und plant die
        -- naechsten Anforderungen. Ohne Manifest kostet Pump nichts.
        Segments.Pump(Config.DecodeBudgetMs)

        -- Weltspur: erst das Fenster nachziehen, dann dekodieren (sonst prueft
        -- sie gegen den Stand des vorigen Bildes und verwirft frisch geladene
        -- Segmente). Das Fenster haengt am Abspielkopf plus Vorratsreichweite,
        -- nicht am geladenen Bereich des Spielerpfads.
        if World then
            local m = Segments.Manifest()
            if m then
                local ss  = tonumber(m.segSec) or 30
                if ss < 1 then ss = 30 end
                local cur = math.floor(segTime(playT) / ss)
                local reach = math.ceil(cfgNum('PrefetchSeconds', 120) / ss) + 2
                -- Das groessere der beiden Fenster (Prefetch- vs. Cache-Reichweite),
                -- sonst loeschte Keep Umgebung, die der Beweisstrom noch haelt.
                local wf, wt = Segments.Window()
                local lo = math.min(cur - reach, wf or (cur - reach))
                local hi = math.max(cur + reach, wt or (cur + reach))
                World.Keep(lo, hi)
            end
            World.Pump(cfgNum('WorldDecodeBudgetMs', 0.7))
        end

        local now = GetGameTimer()
        local frameMs = now - last; last = now
        if not active then goto continue end

        HideHudAndRadarThisFrame()

        -- Lebende Bevoelkerung unterdruecken: der Ambient-Verkehr des Zuschauers
        -- war zum Aufzeichnungszeitpunkt nicht da (leer und ehrlich > erfunden).
        if Config.Playback.SuppressAmbient ~= false then
            SetPedDensityMultiplierThisFrame(0.0)
            SetVehicleDensityMultiplierThisFrame(0.0)
            SetRandomVehicleDensityMultiplierThisFrame(0.0)
            SetParkedVehicleDensityMultiplierThisFrame(0.0)
            SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)
            SetGarbageTrucks(false)
            SetRandomBoats(false)
            SetCreateRandomCops(false)
        end

        -- Steuerung ---------------------------------------------------------
        -- Alles sperren, nur Chat frei; unsere Kuerzel lesen wir als gesperrte
        -- Eingaben (IsDisabledControl…).
        DisableAllControlActions(0)
        EnableControlAction(0, 245, true)   -- T: Chat oeffnen

        if not IsPauseMenuActive() and GetGameTimer() > (chatBlockUntil or 0) then
            -- ESCAPE: Zeiger umschalten (im Zeigermodus schaltet die NUI zurueck).
            if IsDisabledControlJustPressed(0, 322) then
                RPSToggleCursor()
            end
            -- LEERTASTE: anhalten / fortsetzen.
            if IsDisabledControlJustPressed(0, 22) then
                playing = not playing
            end
            -- A / D: spulen, nur in der Folgekamera (in der Freikamera bewegen sie sie).
            if followMode then
                local d = 0
                if IsDisabledControlPressed(0, 34) then d = -1 end   -- A
                if IsDisabledControlPressed(0, 35) then d =  1 end    -- D
                if d ~= 0 then
                    local sp = cfgNum('SeekHoldSpeed', 6.0)          -- s Aufnahme / s
                    playT = clamp(playT + d * sp * (frameMs / 1000.0), 0, duration)
                    playing = false
                    scrubbing = true
                    scrubUntil = GetGameTimer() + 200
                end
            end
        end

        -- Zeit ------------------------------------------------------------
        -- Fortgeschrieben wird erst am Ende des Bildes.
        if scrubbing and now > scrubUntil then scrubbing = false end

        -- Puffern nach einem Sprung aufloesen, sobald der verfolgte Spieler
        -- wieder Daten hat oder die Geduld abgelaufen ist.
        if seekHold then
            local fa0 = actors[focusIdx]
            local _, _, _, st0 = sampleAt(fa0, playT)
            if st0 == 'ok' or st0 == 'gap' or now > seekHoldTo then
                seekHold = false
            end
        end
        applyWorldState()

        -- Actors positionieren --------------------------------------------
        local despawnMs = cfgNum('ActorDespawnSeconds', 20.0) * 1000.0
        local fa = actors[focusIdx]

        for _, a in ipairs(actors) do
            -- Faules Spawnen gibt ab; hat ein neues Manifest die Akteure getauscht,
            -- passen die Indizes nicht mehr. Ein Bild auslassen kostet nichts.
            if a.gen ~= sessionGen then break end

            local s1, s2, f, state = sampleAt(a, playT)
            a.state = state

            -- 'stale' heisst nicht 'weg': ein Klon darf davon nicht altern, sonst
            -- wird aus einer Ladepause ein optisches 'gap'.
            if state ~= 'gap' or buffering then
                a.dataAt = now
            end

            if state == 'ok' and s1 then
                -- Aus der Ladepause zurueck: Einfrieren und Abdunklung aufheben.
                if a.stalled then
                    a.stalled = false
                    if a.clonePed and DoesEntityExist(a.clonePed) then
                        FreezeEntityPosition(a.clonePed, false)
                    end
                    if a.cloneVeh and DoesEntityExist(a.cloneVeh) then
                        FreezeEntityPosition(a.cloneVeh, false)
                    end
                    setAlpha(a, 255)
                    a.warp = true   -- hart setzen statt den Weg nachlaufen
                end

                local x = lerp(s1.x, s2.x, f)
                local y = lerp(s1.y, s2.y, f)
                local z = lerp(s1.z, s2.z, f)
                local h = lerpHeading(s1.heading, s2.heading, f)

                -- Kamera/Datenband lesen aus den Daten, nicht aus dem Klon:
                -- ein Spieler ohne Klon bleibt verfolgbar.
                if a == fa then
                    lastTargetPos = vector3(x, y, z)
                    -- Beim ersten Zustand hinter den Spieler schwenken.
                    if not a.camAligned then a.camAligned = true; orbitYaw = h end
                end

                local fs = fidAt(a, playT)
                local ped = ensureClone(a, x, y, z, h)
                if ped then
                    SetEntityVisible(ped, true, false)
                    setAlpha(a, 255)

                    -- Rueckkehr aus einer Luecke: hart setzen, nicht zulaufen
                    -- (sonst laeuft der Ped die Strecke quer ueber die Karte ab).
                    if a.hidden then
                        a.hidden = false
                        FreezeEntityPosition(ped, false)
                        a.warp = true
                    end
                    if a.warp then
                        a.warp = false
                        a.dead = false          -- Haltung am neuen Ort neu setzen
                        -- Der Sprung nimmt den Ped aus jedem Sitz.
                        a.inVeh = false
                        ClearPedTasksImmediately(ped)
                        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
                        SetEntityHeading(ped, h)
                        a.lastTaskAt = 0
                        a.lastVehPos = nil
                        a.posLead    = nil
                    end

                    if s1.vehModel and s1.vehModel ~= 0 then
                        ensureVehicle(a, s1.vehModel, s1.vehSeat)
                        local v = a.cloneVeh
                        if v and DoesEntityExist(v) then
                            SetEntityVisible(v, true, false)
                            setAlpha(a, 255)
                            -- Aus einer Luecke zurueck: Einfrieren aufheben (im
                            -- Versuchsmodus VehicleFreeze bewusst nicht).
                            if a.vehFrozen and not Config.Playback.VehicleFreeze then
                                FreezeEntityPosition(v, false); a.vehFrozen = false
                            end

                            -- Erst messen, dann versetzen (Teleport setzt den
                            -- Radzustand zurueck; wer danach misst, misst ihn mit).
                            ensureWheelInfo(a, v)
                            probeWheels(a, v)

                            -- Fahren statt versetzen, wenn eingeschaltet (driveVehicle).
                            local drove = false
                            if Config.Playback.VehicleDrive then
                                local rate = (playing and not scrubbing and not buffering)
                                             and (speed * playDir) or 0.0
                                driveVehicle(a, v, s1, s2, x, y, z, h, rate)
                                drove = true
                            end

                            local tx, ty, tz = x, y, z
                            if not drove then
                                if Config.Playback.VehicleLeadCompensation ~= false and a.leadVec then
                                    -- Grosser Wert = Zeitsprung, nicht Integration: nicht kompensieren.
                                    if #a.leadVec < 3.0 then
                                        tx = x - a.leadVec.x
                                        ty = y - a.leadVec.y
                                        tz = z - a.leadVec.z
                                    end
                                end

                                SetEntityCoordsNoOffset(v, tx, ty, tz, false, false, false)
                                SetEntityRotation(v, s1.vpitch or 0.0, s1.vroll or 0.0, h, 2, true)
                                -- Gegen den tatsaechlich gesetzten Punkt messen.
                                a.lastVehPos = vector3(tx, ty, tz)
                            end

                            -- Alter Radschreibweg; im Fahrbetrieb aus (setzt selbst Tempo).
                            if Config.Playback.VehicleWheelSpin and not drove then
                                -- Tempo interpolieren, sonst zucken die Raeder (Quantisierung).
                                local sp  = lerp(s1.speed or 0.0, s2.speed or 0.0, f)
                                local dir = rotToDir(0.0, h)

                                -- Recorder speichert einen Betrag ohne Vorzeichen;
                                -- Vorzeichen aus der Fahrtrichtung rekonstruieren.
                                local dx, dy = s2.x - s1.x, s2.y - s1.y
                                if (dx * dir.x + dy * dir.y) < 0.0 then sp = -sp end

                                -- Mit dem Wiedergabetempo skalieren.
                                local rate = (playing and not scrubbing and not buffering)
                                             and (speed * playDir) or 0.0
                                sp = sp * rate

                                releaseBrakes(a, v)
                                pushWheels(a, v, sp)

                                -- Geschwindigkeit als Eingang des Radmodells (bewegt den
                                -- Klon nicht). 'track' nimmt Betrag und Richtung aus der
                                -- Bahn, auch im Schleudern richtig; Hochachse mitgefuehrt.
                                local vsrc = Config.Playback.VehicleVelocitySource or 'track'
                                local dt   = s2.relT - s1.relT
                                if vsrc == 'track' and dt > 0.001 then
                                    SetEntityVelocity(v,
                                        (s2.x - s1.x) / dt * rate,
                                        (s2.y - s1.y) / dt * rate,
                                        (s2.z - s1.z) / dt * rate)
                                elseif vsrc ~= 'none' then
                                    SetEntityVelocity(v, dir.x * sp, dir.y * sp, 0.0)
                                end

                                spinWheels(a, v, sp)
                            end
                            -- Lenkwinkel (CFX-Native, defensiv aufgerufen)
                            pcall(function()
                                Citizen.InvokeNative(0xFFCCC2EA, v, (s1.steer or 0.0) + 0.0)
                            end)
                            -- Im Versuchsmodus Motor aus (wie Weltfahrzeug).
                            if not Config.Playback.VehicleFreeze then
                                SetVehicleEngineOn(v, true, true, false)
                            end
                            applyFidelityVehicle(a, fs)
                            -- Die Engine fragen, nicht die eigene Buchfuehrung: ein
                            -- Klon kann den Sitz auf ungesehenen Wegen verlassen.
                            if not IsPedInVehicle(a.clonePed, v, false) then
                                -- Ein Toter laesst sich nicht setzen: erst zurueckschalten.
                                if a.seatDead then setSeatedDeath(a, false) end
                                SetPedIntoVehicle(a.clonePed, v, s1.vehSeat or -1)
                            end
                            a.inVeh = IsPedInVehicle(a.clonePed, v, false)
                            -- Tod im Sitz (hier, weil der Fahrzeugzweig ihn sonst nicht sieht).
                            setSeatedDeath(a, (s1.flags & Protocol.FLAG.ALIVE) == 0)
                        else
                            -- Kein Fahrzeugklon (Modell fehlt/Pool erschoepft):
                            -- der Ped muss trotzdem der Aufzeichnung folgen.
                            a.inVeh = false
                            SetEntityCoordsNoOffset(a.clonePed, x, y, z, false, false, false)
                            SetEntityHeading(a.clonePed, h)
                        end
                    else
                        if a.cloneVeh then removeVehicle(a); a.inVeh = false end
                        -- Aus dem Sitz: Unverwundbarkeit wiederherstellen.
                        setSeatedDeath(a, false)
                        -- Ragdoll kennt nur der Client genau.
                        local ragdoll  = fs and (fs.flags & Fidelity.P.RAGDOLL) ~= 0
                        local downed   = (s1.flags & Protocol.FLAG.ALIVE) == 0
                        local aliveNow = not downed and not ragdoll
                        if not aliveNow then
                            if not a.dead then
                                a.dead = true
                                SetEntityCoordsNoOffset(a.clonePed, x, y, z, false, false, false)
                                SetPedToRagdoll(a.clonePed, 60000, 60000, 0, false, false, false)
                            else
                                -- Auch ein liegender Koerper muss der Aufzeichnung folgen.
                                local moved = #(GetEntityCoords(a.clonePed) - vector3(x, y, z))
                                if (not playing) or scrubbing or playDir < 0
                                   or moved > Config.Playback.DriftCorrection then
                                    SetEntityCoordsNoOffset(a.clonePed, x, y, z, false, false, false)
                                end
                            end
                        else
                            if a.dead then
                                a.dead = false
                                ClearPedTasksImmediately(a.clonePed)
                                -- Nur nach echtem Tod wiederbeleben (sonst setzt
                                -- ResurrectPed die Health beim Stolpern zurueck).
                                if IsPedDeadOrDying(a.clonePed, true) then
                                    ResurrectPed(a.clonePed)
                                    SetEntityHealth(a.clonePed, math.max(101, s1.health or 200))
                                end
                                a.lastBlend = -1; a.lastTaskAt = 0
                            end
                            drivePed(a, s1, s2, f, x, y, z, h, now)
                            applyFidelityPed(a, fs)
                        end
                    end

                    if Config.Playback.ShowNameTags or Config.Playback.ShowStatusBars then
                        local tagPos = (a.cloneVeh and DoesEntityExist(a.cloneVeh))
                            and GetEntityCoords(a.cloneVeh) or GetEntityCoords(a.clonePed)
                        drawNameTag(tagPos, a, s1, fs, a == fa)
                    end
                end

            elseif state == 'gap' then
                -- Spieler war nicht auf dem Server: Klon unsichtbar, Fahrzeug
                -- abraeumen (ein unsichtbarer Wagen fuehre sonst weiter).
                if a.clonePed and DoesEntityExist(a.clonePed) then
                    if not a.hidden then
                        a.hidden = true
                        ClearPedTasksImmediately(a.clonePed)
                        SetEntityVisible(a.clonePed, false, false)
                        FreezeEntityPosition(a.clonePed, true)
                        a.inVeh = false
                    end
                end
                if a.cloneVeh then removeVehicle(a); a.inVeh = false end

            else
                -- 'stale': laedt noch. Klon bleibt stehen und wird abgedunkelt,
                -- nicht ausgeblendet (das hiesse "war nicht da").
                if a.clonePed and DoesEntityExist(a.clonePed) then
                    -- Aus einer Luecke zurueck: wieder sichtbar machen.
                    if a.hidden then
                        a.hidden = false
                        SetEntityVisible(a.clonePed, true, false)
                    end
                    setAlpha(a, STALE_ALPHA)

                    -- Wirklich stehenbleiben, sonst laeuft ein Laufauftrag weiter.
                    if not a.stalled then
                        a.stalled = true
                        ClearPedTasks(a.clonePed)
                        FreezeEntityPosition(a.clonePed, true)
                        if a.cloneVeh and DoesEntityExist(a.cloneVeh) then
                            SetEntityVelocity(a.cloneVeh, 0.0, 0.0, 0.0)
                            FreezeEntityPosition(a.cloneVeh, true)
                        end
                    end
                end
            end

            -- Nach einer Weile ohne Daten abraeumen — aber nur bei 'gap'
            -- (nachweislich nicht da), nicht bei ungeladen.
            if state == 'gap' and a.clonePed
               and (now - (a.dataAt or now)) > despawnMs then
                removeActorClone(a)
            end
        end

        -- Umgebung: Fahrzeuge ohne Insassen -------------------------------
        -- Bezugspunkt ist die Kamera des vorigen Bildes (ein Bild Versatz
        -- unmerklich, erspart einen zweiten Durchlauf).
        updateWorldVehicles(playT, camPos)

        -- Waehrend der Actor-Schleife kann ein Manifest/Schliessen dazwischen sein.
        if not active or not cam then goto continue end

        -- Kamera ----------------------------------------------------------
        -- focusPos() liefert in Luecke/Puffern nichts; dann letzte Position halten.
        local target = focusPos() or lastTargetPos or camPos
        if followMode then
            if not cursorMode then
                orbitYaw   = orbitYaw - GetDisabledControlNormal(0, 1) * 8.0
                orbitPitch = clamp(orbitPitch + GetDisabledControlNormal(0, 2) * 8.0, -80.0, 85.0)
                if IsDisabledControlPressed(0, 241) then orbitDist = math.max(2.0, orbitDist - 0.4) end
                if IsDisabledControlPressed(0, 242) then orbitDist = math.min(80.0, orbitDist + 0.4) end
            end
            local rp = math.rad(orbitPitch); local horiz = orbitDist * math.cos(rp)
            local back = rotToDir(0.0, orbitYaw)
            camPos = vector3(target.x - back.x * horiz, target.y - back.y * horiz,
                             target.z + orbitDist * math.sin(rp) + 0.4)
            camYaw, camPitch = aimAt(camPos, vector3(target.x, target.y, target.z + 0.4))
        elseif not cursorMode then
            camYaw   = camYaw - GetDisabledControlNormal(0, 1) * 8.0
            camPitch = clamp(camPitch - GetDisabledControlNormal(0, 2) * 8.0, -89.0, 89.0)
            local dir = rotToDir(camPitch, camYaw)
            local right = vector3(math.cos(math.rad(camYaw)), math.sin(math.rad(camYaw)), 0.0)
            local mv = IsDisabledControlPressed(0, 21) and 1.4 or 0.45
            if IsDisabledControlPressed(0, 32) then camPos = camPos + dir * mv end
            if IsDisabledControlPressed(0, 33) then camPos = camPos - dir * mv end
            if IsDisabledControlPressed(0, 34) then camPos = camPos - right * mv end
            if IsDisabledControlPressed(0, 35) then camPos = camPos + right * mv end
        end
        SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
        SetCamRot(cam, camPitch, 0.0, camYaw, 2)

        -- GTA streamt um den Spieler-Ped, nicht um die Kamera; der Ped steht aber
        -- eingefroren. Ohne diesen Hinweis bleibt die Szene grob verpixelt.
        SetFocusPosAndVel(camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0)

        nuiState(now)
        nuiTelemetryTick(now)

        -- Zeit fortschreiben — zuletzt im Bild ----------------------------
        -- Puffern: der naechste Zeitpunkt wird nur uebernommen, wenn der Cache
        -- Material hat; 'stale' haelt playT an (wie ein Videoplayer). Eine
        -- Luecke ('gap') haelt nicht an. Am Ende, weil Segments.SampleAt den
        -- Abspielkopf des Caches mitfuehrt (Laufrichtung/Vorrat haengen daran).
        buffering = false
        if playing and seekHold then buffering = true end
        if playing and not scrubbing and not seekHold then
            local want = playT + (frameMs / 1000.0) * speed * playDir

            if want >= duration or want <= 0 then
                -- Bandende ist ein Sprung, kein Fortschreiten: ueber seekTo, damit
                -- der Cache-Abspielkopf nicht ans Gegenende gezogen wird.
                seekTo(want >= duration and 0.0 or duration)
            else
                local _, _, _, st = sampleAt(actors[focusIdx], want)
                if st == 'stale' then
                    buffering = true
                else
                    playT = want
                end
            end
        end
        ::continue::
    end
end)

-- Beim Stoppen der Resource aufraeumen: sonst blieben bei einem Neustart
-- waehrend eines offenen Replays Klone, Kamera und der eingefrorene eigene Ped
-- stehen und der Admin haengt unsichtbar in der Welt.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if active then teardown(false) end
end)

--- Laeuft gerade eine Wiedergabe? Fuer client/scene.lua: die Klone stehen ohne
--- Routing-Bucket in der lebenden Welt, ein Szenen-Aufzeichner darf sie nicht
--- als Umgebung aufnehmen.
function RPSPlaybackActive()
    return active and true or false
end
