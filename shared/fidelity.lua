--[[ D-RPS — shared/fidelity.lua
     Zweiter Datenstrom: nur clientseitige Angaben (Gang/Zielen/Blickrichtung etc.).
     Bewusst getrennt vom Evidence-Format: eigene Dateien/Ring/Zeitachse, client-
     gemeldet und faelschbar (nur Optik, nie Beweis); Ausfall laesst Replay laufen.
     Gleiche Bauart: Delta gegen Vorgaenger, Masken-Byte davor, gepackter String. ]]

Fidelity = {}

Fidelity.VERSION = 2
Fidelity.MAGIC   = 0xD6

-- Feldmaske (u8).
Fidelity.F = {
    FLAGS   = 0x01,   -- u16 Bewegungs- und Zustandsbits
    CAM     = 0x02,   -- i16 Yaw + i16 Pitch (Pitch gibt es nur hier)
    BLEND   = 0x04,   -- u8  Bewegungsmischung 0..3
    HEADING = 0x08,   -- u16 exakte Blickrichtung des Peds
    VEHICLE = 0x10,   -- i8 Lenkwinkel + u8 Fahrzeugzustand
    WEAPON  = 0x20,   -- u32 Hash der gefuehrten Waffe
    AMMO    = 0x40,   -- u16 Munition im Magazin
}
Fidelity.KEYFRAME_MASK = 0xFF

-- Zustandsbits des Peds (u16). Reicher als Evidence: Client fragt direkt ab.
Fidelity.P = {
    WALKING   = 0x0001,
    RUNNING   = 0x0002,
    SPRINTING = 0x0004,
    JUMPING   = 0x0008,
    IN_COVER  = 0x0010,
    AIMING    = 0x0020,
    SHOOTING  = 0x0040,
    RELOADING = 0x0080,
    RAGDOLL   = 0x0100,
    SWIMMING  = 0x0200,
    CLIMBING  = 0x0400,
    CROUCH    = 0x0800,
    FALLING   = 0x1000,
    PARACHUTE = 0x2000,
    IN_VEH    = 0x4000,
    DRIVER    = 0x8000,
}

-- Zustandsbits des Fahrzeugs (u8).
Fidelity.V = {
    LIGHTS    = 0x01,
    HIGHBEAM  = 0x02,
    INDIC_L   = 0x04,
    INDIC_R   = 0x08,
    SIREN     = 0x10,
    BRAKING   = 0x20,
    DOOR_OPEN = 0x40,
    ENGINE    = 0x80,
}

local floor = math.floor
local function clampI(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function degToU16(d) return floor((d % 360.0) / 360.0 * 65535 + 0.5) end
local function u16ToDeg(v) return v / 65535.0 * 360.0 end

local function angToI16(d)
    if d > 180.0 then d = d - 360.0 end
    return floor(clampI(d, -180.0, 180.0) / 180.0 * 32767 + 0.5)
end
local function i16ToAng(v) return v / 32767.0 * 180.0 end

local function steerToI8(d) return floor(clampI(d * 2.0, -127, 127) + 0.5) end
local function i8ToSteer(v) return v / 2.0 end
local function blendToU8(b) return floor(clampI(b / 3.0 * 255, 0, 255) + 0.5) end

local KF_FMT = '<I2 I1 I2 i2i2 I1 I2 i1I1 I4 I2'

-- ===========================================================================
-- Kodierung
-- ===========================================================================

function Fidelity.EncodeKeyframe(s, dtMs)
    return string.pack(KF_FMT,
        dtMs or 0,
        Fidelity.KEYFRAME_MASK,
        s.flags or 0,
        angToI16(s.camYaw or 0.0), angToI16(s.camPitch or 0.0),
        blendToU8(s.blend or 0.0),
        degToU16(s.heading or 0.0),
        steerToI8(s.steer or 0.0), s.vflags or 0,
        (s.weapon or 0) & 0xFFFFFFFF,
        math.min(65535, s.ammo or 0))
end

function Fidelity.EncodeDelta(prev, s, dtMs)
    local mask, parts, n = 0, {}, 0

    if (s.flags or 0) ~= (prev.flags or 0) then
        mask = mask | Fidelity.F.FLAGS
        n = n + 1; parts[n] = string.pack('<I2', s.flags or 0)
    end

    local cy, pcy = angToI16(s.camYaw or 0.0),   angToI16(prev.camYaw or 0.0)
    local cp, pcp = angToI16(s.camPitch or 0.0), angToI16(prev.camPitch or 0.0)
    if cy ~= pcy or cp ~= pcp then
        mask = mask | Fidelity.F.CAM
        n = n + 1; parts[n] = string.pack('<i2i2', cy, cp)
    end

    local b, pb = blendToU8(s.blend or 0.0), blendToU8(prev.blend or 0.0)
    if b ~= pb then
        mask = mask | Fidelity.F.BLEND
        n = n + 1; parts[n] = string.pack('<I1', b)
    end

    local h, ph = degToU16(s.heading or 0.0), degToU16(prev.heading or 0.0)
    if h ~= ph then
        mask = mask | Fidelity.F.HEADING
        n = n + 1; parts[n] = string.pack('<I2', h)
    end

    local st, pst = steerToI8(s.steer or 0.0), steerToI8(prev.steer or 0.0)
    if st ~= pst or (s.vflags or 0) ~= (prev.vflags or 0) then
        mask = mask | Fidelity.F.VEHICLE
        n = n + 1; parts[n] = string.pack('<i1I1', st, s.vflags or 0)
    end

    if (s.weapon or 0) ~= (prev.weapon or 0) then
        mask = mask | Fidelity.F.WEAPON
        n = n + 1; parts[n] = string.pack('<I4', (s.weapon or 0) & 0xFFFFFFFF)
    end

    if (s.ammo or 0) ~= (prev.ammo or 0) then
        mask = mask | Fidelity.F.AMMO
        n = n + 1; parts[n] = string.pack('<I2', math.min(65535, s.ammo or 0))
    end

    return string.pack('<I2I1', dtMs or 0, mask) .. table.concat(parts, '', 1, n)
end

-- ===========================================================================
-- Dekodierung
-- ===========================================================================

function Fidelity.DecodeKeyframe(data, pos)
    local dt, _, flags, cy, cp, b, h, st, vf, w, am, nextPos =
        string.unpack(KF_FMT, data, pos)
    return {
        dt = dt, flags = flags,
        camYaw = i16ToAng(cy), camPitch = i16ToAng(cp),
        blend = b / 255.0 * 3.0,
        heading = u16ToDeg(h),
        steer = i8ToSteer(st), vflags = vf, weapon = w, ammo = am,
    }, nextPos
end

function Fidelity.ApplyStep(data, pos, prev)
    local dt, mask = string.unpack('<I2I1', data, pos)
    if mask == Fidelity.KEYFRAME_MASK then
        return Fidelity.DecodeKeyframe(data, pos)
    end

    pos = pos + 3
    local s = {
        dt = dt, flags = prev.flags,
        camYaw = prev.camYaw, camPitch = prev.camPitch,
        blend = prev.blend, heading = prev.heading,
        steer = prev.steer, vflags = prev.vflags, weapon = prev.weapon,
        ammo = prev.ammo,
    }

    if mask & Fidelity.F.FLAGS ~= 0 then
        s.flags, pos = string.unpack('<I2', data, pos)
    end
    if mask & Fidelity.F.CAM ~= 0 then
        local cy, cp; cy, cp, pos = string.unpack('<i2i2', data, pos)
        s.camYaw = i16ToAng(cy); s.camPitch = i16ToAng(cp)
    end
    if mask & Fidelity.F.BLEND ~= 0 then
        local b; b, pos = string.unpack('<I1', data, pos); s.blend = b / 255.0 * 3.0
    end
    if mask & Fidelity.F.HEADING ~= 0 then
        local h; h, pos = string.unpack('<I2', data, pos); s.heading = u16ToDeg(h)
    end
    if mask & Fidelity.F.VEHICLE ~= 0 then
        s.steer, s.vflags, pos = string.unpack('<i1I1', data, pos)
        s.steer = i8ToSteer(s.steer)
    end
    if mask & Fidelity.F.WEAPON ~= 0 then
        s.weapon, pos = string.unpack('<I4', data, pos)
    end
    if mask & Fidelity.F.AMMO ~= 0 then
        s.ammo, pos = string.unpack('<I2', data, pos)
    end
    return s, pos
end

-- == Chunk-Rahmen ==

function Fidelity.EncodeChunkHeader(startSec, startMs, playerHash, nSamples)
    return string.pack('<I1 I1 I4 I2 I4 I2',
        Fidelity.MAGIC, Fidelity.VERSION,
        startSec, startMs, playerHash & 0xFFFFFFFF, nSamples)
end

function Fidelity.DecodeChunkHeader(data)
    if #data < 14 then return nil end
    local magic, ver, startSec, startMs, playerHash, nSamples, pos =
        string.unpack('<I1 I1 I4 I2 I4 I2', data)
    if magic ~= Fidelity.MAGIC or ver ~= Fidelity.VERSION then return nil end
    return { version = ver, startSec = startSec, startMs = startMs,
             playerHash = playerHash, nSamples = nSamples }, pos
end

function Fidelity.DecodeChunk(chunkStr)
    local hdr, pos = Fidelity.DecodeChunkHeader(chunkStr)
    if not hdr then return nil end
    local states, cur = {}, nil
    local ok = pcall(function()
        for i = 1, hdr.nSamples do
            cur, pos = Fidelity.ApplyStep(chunkStr, pos, cur or {})
            states[i] = cur
        end
    end)
    if not ok or #states == 0 then return nil end
    return states, hdr
end

return Fidelity
