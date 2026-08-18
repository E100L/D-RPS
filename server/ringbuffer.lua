--[[ D-RPS — server/ringbuffer.lua
     RAM-Ringpuffer fuer geschlossene Chunks pro Spieler (FIFO). Haelt nur das
     juengste Fenster (Config.RamBufferMinutes); Langzeitarchiv auf Disk.
     Ein Chunk = ein gepackter String = ein GC-Objekt -> Speicher bleibt flach. ]]

RingBuffer = {}
RingBuffer.__index = RingBuffer

-- Chunk-Laenge = Segmentlaenge (Recorder schliesst an Segmentgrenze),
-- DiskChunkSeconds ist nur Obergrenze. Mit dem groesseren Wert zu rechnen liesse
-- den Ring nur einen Bruchteil der zugesagten Minuten halten.
local function chunkSeconds()
    local seg = (Session and Session.SegSeconds) and Session.SegSeconds() or nil
    local cap = Config.DiskChunkSeconds or 60
    if seg and seg > 0 then return math.min(seg, cap) end
    return cap
end

local function slotCount()
    local secs = Config.RamBufferMinutes * 60
    return math.max(2, math.ceil(secs / chunkSeconds()))
end

--- Neuen Ring fuer einen Spieler anlegen.
function RingBuffer.new()
    return setmetatable({
        slots = {},          -- [1..N] gepackte Chunk-Strings
        meta  = {},          -- [1..N] { startSec, startMs, nSamples, bytes }
        head  = 1,           -- naechster Schreibindex
        count = 0,           -- wie viele Slots belegt
        cap   = slotCount(),
        totalBytes = 0,      -- fuer /rps_stats
    }, RingBuffer)
end

--- Geschlossenen Chunk einlegen. Ueberschreibt den aeltesten, wenn voll.
function RingBuffer:push(chunkStr, startSec, startMs, nSamples)
    local i   = self.head
    local old = self.slots[i]
    if old then self.totalBytes = self.totalBytes - #old end

    self.slots[i] = chunkStr
    self.meta[i]  = { startSec = startSec, startMs = startMs,
                      nSamples = nSamples, bytes = #chunkStr }
    self.totalBytes = self.totalBytes + #chunkStr

    self.head = (i % self.cap) + 1
    if self.count < self.cap then self.count = self.count + 1 end
end

--- Alle im Ring liegenden Chunks in chronologischer Reihenfolge iterieren.
--- Callback: fn(chunkStr, meta)
function RingBuffer:each(fn)
    -- aeltester Slot: bei vollem Ring ist das head, sonst 1
    local start = (self.count < self.cap) and 1 or self.head
    for k = 0, self.count - 1 do
        local i = ((start - 1 + k) % self.cap) + 1
        if self.slots[i] then fn(self.slots[i], self.meta[i]) end
    end
end

--- Chunks, die ein Zeitfenster [fromSec, toSec] beruehren (fuer spaeteres
--- Segment-Streaming ans Playback). Gibt eine Liste gepackter Strings zurueck.
function RingBuffer:window(fromSec, toSec)
    local out = {}
    self:each(function(chunk, meta)
        local endSec = meta.startSec + Config.DiskChunkSeconds
        if endSec >= fromSec and meta.startSec <= toSec then
            out[#out + 1] = chunk
        end
    end)
    return out
end

return RingBuffer
