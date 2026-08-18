--[[ D-RPS — shared/protocol.lua
     Binaerformat der Zustandsdaten (string.pack, ein Chunk = ein GC-Objekt).
     Geteilt: Server encodet beim Recording, Client decodet beim Playback.
     Jeder Sample traegt echtes dt in ms (Scheduler ungenau: Wait(50) ≈ 64 ms). ]]

Protocol = {}

Protocol.VERSION = 3
Protocol.MAGIC   = 0xD5   -- "D-RPS"-Signaturbyte am Chunk-Anfang

-- Feld-Bitmaske (u16). Sample = dt(u16) + Maske(u16), danach nur gesetzte Felder.
Protocol.F = {
    POS       = 0x0001,   -- i16 dx,dy,dz  (Zentimeter-Delta)
    HEADING   = 0x0002,   -- u16           (0..65535 ueber 360°)
    HEALTH    = 0x0004,   -- u8 health + u8 armour
    FLAGS     = 0x0008,   -- u16 Zustands-Bitfeld
    VEHICLE   = 0x0010,   -- u32 Model + i8 Sitz  (Model 0 = zu Fuss)
    CAMERA    = 0x0020,   -- i16 yaw + i16 pitch
    MOVEBLEND = 0x0040,   -- u8 (0..255 → 0.0..3.0)
    VEHDYN    = 0x0080,   -- i8 Lenkwinkel(0,5°) + u8 Tempo(0,5 m/s)
    TILT      = 0x0100,   -- i8 Nick + i8 Roll (Grad) — Fahrzeugneigung
}

-- Vollstaendige Maske = Keyframe. Position wird dann ABSOLUT (i32) geschrieben.
Protocol.KEYFRAME_MASK = 0xFFFF

-- Zustands-Flags eines Peds.
Protocol.FLAG = {
    ALIVE      = 0x0001,
    IN_VEHICLE = 0x0002,
    IS_DRIVER  = 0x0004,
    RAGDOLL    = 0x0008,
    WALKING    = 0x0010,
    RUNNING    = 0x0020,
    SPRINTING  = 0x0040,
    JUMPING    = 0x0080,
    IN_COVER   = 0x0100,
    AIMING     = 0x0200,
    SHOOTING   = 0x0400,
    RELOADING  = 0x0800,
    FALLING    = 0x1000,
    SWIMMING   = 0x2000,
    PARACHUTE  = 0x4000,
    IS_VEHICLE = 0x8000,   -- unbesetztes Fahrzeug (Weltspur); Wiedergabe baut nur ein Fahrzeug, keinen Ped

}

-- Sammelschluessel des Weltstroms: alle unbesetzten Fahrzeuge in EINER Tagesdatei/
-- EINEM Segment (sonst tausende Dateien/Tag). Fahrzeug-Identitaet steht im Chunk-Kopf,
-- ein Chunk gehoert weiter zu genau einer Entitaet und einem Segment.
-- Kollision mit einem Spielerpseudonym: 1 zu 4,3 Mrd, Recorder.StartPlayer meldet sie.
Protocol.WORLD_HASH = 0xD5000001

-- Positions-Delta in i16 (cm): ±320 m/Sample. Ueberlauf = Teleport -> Keyframe erzwingen.
local DELTA_LIMIT_CM = 32000

local floor = math.floor
local function clampI(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- == Quantisierung ==

local function headingToU16(h) return floor((h % 360.0) / 360.0 * 65535 + 0.5) end
local function u16ToHeading(v) return v / 65535.0 * 360.0 end

local function camToI16(deg)
    if deg > 180.0 then deg = deg - 360.0 end
    return floor(clampI(deg, -180.0, 180.0) / 180.0 * 32767 + 0.5)
end
local function i16ToCam(v) return v / 32767.0 * 180.0 end

local function steerToI8(deg) return floor(clampI(deg * 2.0, -127, 127) + 0.5) end
local function i8ToSteer(v)   return v / 2.0 end
local function speedToU8(ms)  return floor(clampI(ms * 2.0, 0, 255) + 0.5) end
local function u8ToSpeed(v)   return v / 2.0 end
local function tiltToI8(deg)  return floor(clampI(deg, -127, 127) + 0.5) end
local function blendToU8(b)   return floor(clampI(b / 3.0 * 255, 0, 255) + 0.5) end

local KF_FMT = '<I2 I2 i4i4i4 I2 I1I1 I2 I4i1 i2i2 I1 i1I1 i1i1'

-- ===========================================================================
-- Kodierung
-- ===========================================================================

--- Keyframe: absoluter Zustand. Chunk-Beginn und wenn ein Delta nicht reicht.
function Protocol.EncodeKeyframe(s, dtMs)
    return string.pack(KF_FMT,
        dtMs or 0,
        Protocol.KEYFRAME_MASK,
        floor(s.x * 100 + 0.5), floor(s.y * 100 + 0.5), floor(s.z * 100 + 0.5),
        headingToU16(s.heading or 0.0),
        s.health or 0, s.armour or 0,
        s.flags or 0,
        (s.vehModel or 0) & 0xFFFFFFFF, s.vehSeat or -1,
        camToI16(s.camYaw or 0.0), camToI16(s.camPitch or 0.0),
        blendToU8(s.moveBlend or 0.0),
        steerToI8(s.steer or 0.0), speedToU8(s.speed or 0.0),
        tiltToI8(s.vpitch or 0.0), tiltToI8(s.vroll or 0.0))
end

--- Delta: nur geaenderte Felder gegen `prev`. Gibt (packedString, isKeyframe).
function Protocol.EncodeDelta(prev, s, dtMs)
    local dx = floor((s.x - prev.x) * 100 + 0.5)
    local dy = floor((s.y - prev.y) * 100 + 0.5)
    local dz = floor((s.z - prev.z) * 100 + 0.5)

    if dx > DELTA_LIMIT_CM or dx < -DELTA_LIMIT_CM
    or dy > DELTA_LIMIT_CM or dy < -DELTA_LIMIT_CM
    or dz > DELTA_LIMIT_CM or dz < -DELTA_LIMIT_CM then
        return Protocol.EncodeKeyframe(s, dtMs), true
    end

    local mask, parts, n = 0, {}, 0

    if dx ~= 0 or dy ~= 0 or dz ~= 0 then
        mask = mask | Protocol.F.POS
        n = n + 1; parts[n] = string.pack('<i2i2i2', dx, dy, dz)
    end

    local h, ph = headingToU16(s.heading or 0.0), headingToU16(prev.heading or 0.0)
    if h ~= ph then
        mask = mask | Protocol.F.HEADING
        n = n + 1; parts[n] = string.pack('<I2', h)
    end

    if (s.health ~= prev.health) or (s.armour ~= prev.armour) then
        mask = mask | Protocol.F.HEALTH
        n = n + 1; parts[n] = string.pack('<I1I1', s.health or 0, s.armour or 0)
    end

    if (s.flags or 0) ~= (prev.flags or 0) then
        mask = mask | Protocol.F.FLAGS
        n = n + 1; parts[n] = string.pack('<I2', s.flags or 0)
    end

    if (s.vehModel or 0) ~= (prev.vehModel or 0) or (s.vehSeat or -1) ~= (prev.vehSeat or -1) then
        mask = mask | Protocol.F.VEHICLE
        n = n + 1; parts[n] = string.pack('<I4i1', (s.vehModel or 0) & 0xFFFFFFFF, s.vehSeat or -1)
    end

    local cy, pcy = camToI16(s.camYaw or 0.0), camToI16(prev.camYaw or 0.0)
    local cp, pcp = camToI16(s.camPitch or 0.0), camToI16(prev.camPitch or 0.0)
    if cy ~= pcy or cp ~= pcp then
        mask = mask | Protocol.F.CAMERA
        n = n + 1; parts[n] = string.pack('<i2i2', cy, cp)
    end

    local mb, pmb = blendToU8(s.moveBlend or 0.0), blendToU8(prev.moveBlend or 0.0)
    if mb ~= pmb then
        mask = mask | Protocol.F.MOVEBLEND
        n = n + 1; parts[n] = string.pack('<I1', mb)
    end

    local st, pst = steerToI8(s.steer or 0.0), steerToI8(prev.steer or 0.0)
    local sp, psp = speedToU8(s.speed or 0.0), speedToU8(prev.speed or 0.0)
    if st ~= pst or sp ~= psp then
        mask = mask | Protocol.F.VEHDYN
        n = n + 1; parts[n] = string.pack('<i1I1', st, sp)
    end

    local tp, ptp = tiltToI8(s.vpitch or 0.0), tiltToI8(prev.vpitch or 0.0)
    local tr, ptr = tiltToI8(s.vroll or 0.0), tiltToI8(prev.vroll or 0.0)
    if tp ~= ptp or tr ~= ptr then
        mask = mask | Protocol.F.TILT
        n = n + 1; parts[n] = string.pack('<i1i1', tp, tr)
    end

    return string.pack('<I2I2', dtMs or 0, mask) .. table.concat(parts, '', 1, n), false
end

-- ===========================================================================
-- Dekodierung
-- ===========================================================================

--- Umkehrung von EncodeKeyframe. Gibt (state, nextPos).
function Protocol.DecodeKeyframe(data, pos)
    local dt, _, xi, yi, zi, hU, hp, ar, flags, vModel, vSeat,
          cy, cp, mb, st, sp, tp, tr, nextPos = string.unpack(KF_FMT, data, pos)
    return {
        dt = dt,
        x = xi / 100.0, y = yi / 100.0, z = zi / 100.0,
        heading = u16ToHeading(hU),
        health = hp, armour = ar, flags = flags,
        vehModel = vModel, vehSeat = vSeat,
        camYaw = i16ToCam(cy), camPitch = i16ToCam(cp),
        moveBlend = mb / 255.0 * 3.0,
        steer = i8ToSteer(st), speed = u8ToSpeed(sp),
        vpitch = tp, vroll = tr,
    }, nextPos
end

--- Umkehrung von EncodeDelta: Delta ab `pos` auf `prev` anwenden.
--- Feld-Reihenfolge MUSS exakt EncodeDelta entsprechen. Gibt (state, nextPos, isKeyframe).
function Protocol.ApplyStep(data, pos, prev)
    local dt, mask = string.unpack('<I2I2', data, pos)
    if mask == Protocol.KEYFRAME_MASK then
        local s, np = Protocol.DecodeKeyframe(data, pos)
        return s, np, true
    end

    pos = pos + 4   -- dt(2) + mask(2)
    local s = {
        dt = dt,
        x = prev.x, y = prev.y, z = prev.z, heading = prev.heading,
        health = prev.health, armour = prev.armour, flags = prev.flags,
        vehModel = prev.vehModel, vehSeat = prev.vehSeat,
        camYaw = prev.camYaw, camPitch = prev.camPitch, moveBlend = prev.moveBlend,
        steer = prev.steer, speed = prev.speed,
        vpitch = prev.vpitch, vroll = prev.vroll,
    }

    if mask & Protocol.F.POS ~= 0 then
        local dx, dy, dz; dx, dy, dz, pos = string.unpack('<i2i2i2', data, pos)
        s.x = prev.x + dx / 100.0; s.y = prev.y + dy / 100.0; s.z = prev.z + dz / 100.0
    end
    if mask & Protocol.F.HEADING ~= 0 then
        local hU; hU, pos = string.unpack('<I2', data, pos); s.heading = u16ToHeading(hU)
    end
    if mask & Protocol.F.HEALTH ~= 0 then
        s.health, s.armour, pos = string.unpack('<I1I1', data, pos)
    end
    if mask & Protocol.F.FLAGS ~= 0 then
        s.flags, pos = string.unpack('<I2', data, pos)
    end
    if mask & Protocol.F.VEHICLE ~= 0 then
        s.vehModel, s.vehSeat, pos = string.unpack('<I4i1', data, pos)
    end
    if mask & Protocol.F.CAMERA ~= 0 then
        local cy, cp; cy, cp, pos = string.unpack('<i2i2', data, pos)
        s.camYaw = i16ToCam(cy); s.camPitch = i16ToCam(cp)
    end
    if mask & Protocol.F.MOVEBLEND ~= 0 then
        local mb; mb, pos = string.unpack('<I1', data, pos); s.moveBlend = mb / 255.0 * 3.0
    end
    if mask & Protocol.F.VEHDYN ~= 0 then
        local st, sp; st, sp, pos = string.unpack('<i1I1', data, pos)
        s.steer = i8ToSteer(st); s.speed = u8ToSpeed(sp)
    end
    if mask & Protocol.F.TILT ~= 0 then
        s.vpitch, s.vroll, pos = string.unpack('<i1i1', data, pos)
    end

    return s, pos, false
end

-- ===========================================================================
-- Chunk-Rahmen
-- ===========================================================================

function Protocol.EncodeChunkHeader(startSec, startMs, playerHash, nSamples)
    return string.pack('<I1 I1 I4 I2 I4 I2',
        Protocol.MAGIC, Protocol.VERSION,
        startSec, startMs, playerHash & 0xFFFFFFFF, nSamples)
end

function Protocol.DecodeChunkHeader(data)
    if #data < 14 then return nil, 'too short' end
    local magic, ver, startSec, startMs, playerHash, nSamples, pos =
        string.unpack('<I1 I1 I4 I2 I4 I2', data)
    if magic ~= Protocol.MAGIC then return nil, 'bad magic' end
    if ver ~= Protocol.VERSION then return nil, 'version ' .. ver end
    return {
        version = ver, startSec = startSec, startMs = startMs,
        playerHash = playerHash, nSamples = nSamples,
    }, pos
end

--- Vollen Chunk dekodieren -> Liste aller Zustaende.
function Protocol.DecodeChunk(chunkStr)
    local hdr, pos = Protocol.DecodeChunkHeader(chunkStr)
    if not hdr then return nil, pos end

    local states, cur = {}, nil
    local ok = pcall(function()
        for i = 1, hdr.nSamples do
            cur, pos = Protocol.ApplyStep(chunkStr, pos, cur or {})
            states[i] = cur
        end
    end)
    if not ok or #states == 0 then return nil, 'decode error' end
    return states, hdr
end

return Protocol
