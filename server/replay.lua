--[[ D-RPS — server/replay.lua
     Befehle zum Oeffnen eines Replays. Sendet nur ein Verzeichnis
     (server/stream.lua: wer/wann/welche Meldungen); Bewegungsdaten holt der
     Client danach segmentweise. Hier bleibt nur die Wahl des Sprungziels. ]]

--- Name des aufrufenden Admins (Oberflaeche braucht ihn fuer "Mir zuweisen").
local function adminName(src)
    return GetPlayerName(src) or ('Admin ' .. src)
end

local function denyAccess(src)
    RPSNotify(src, 'Replay', 'Kein Zugriff',
        'Dir fehlt die Berechtigung fuer diese Funktion.', 'CHAR_BLOCKED')
end

--- Replay oeffnen. Ohne Argument am aktuellen Rand; eine Server-ID waehlt direkt vor.
local function openReplay(source, args)
    if source == 0 then print('Der Befehl muss ingame ausgefuehrt werden'); return end
    if not RPSIsAdmin(source) then denyAccess(source); return end

    -- Intern ueber Pseudonym, damit auch ausgeloggte Spieler verfolgbar bleiben.
    local focusId   = tonumber(args and args[1] or nil)
    local focusHash = focusId and RPSPlayerHash(focusId) or RPSPlayerHash(source)

    -- Sprungziel bewusst NICHT "jetzt": am Live-Rand liegt noch nichts vor.
    local now  = os.time()
    local back = math.max(60, math.floor((Config.SegmentSeconds or 30) * 4))

    Stream.SendManifest(source, {
        focusHash = focusHash,
        centerSec = now,
        jumpT     = now - back,
        me        = adminName(source),
    })
end

RegisterCommand('replay',     openReplay, false)
RegisterCommand('rps_replay', openReplay, false)   -- Altbezeichnung

--- Direkt zu einer Meldung springen: /ticket_open <id> (Kurzform /incident)
local function openTicket(source, args)
    if source == 0 then return end
    if not RPSIsAdmin(source) then denyAccess(source); return end

    local id = tonumber(args and args[1] or nil)
    if not id then RPSNotifySimple(source, 'Nutzung: ~b~/ticket_open <Nummer>'); return end

    local tk = Tickets.Get(id)
    if not tk then
        RPSNotify(source, 'Meldung', 'Nicht gefunden',
            ('Es gibt keine Meldung mit der Nummer ~y~#%d~w~.'):format(id), 'CHAR_BLOCKED')
        return
    end

    -- Ausserhalb der Aufbewahrungsfrist gibt es keine Aufzeichnung mehr.
    if Config.RetentionDays > 0 and tk.t < (os.time() - Config.RetentionDays * 86400) then
        RPSNotify(source, 'Meldung', 'Ausserhalb der Aufbewahrung',
            ('Die Meldung ist aelter als ~y~%d Tage~w~; die Aufzeichnung wurde geloescht.')
                :format(Config.RetentionDays), 'CHAR_BLOCKED')
        return
    end

    -- Kamera auf den Melder, Zeitachse auf den ZEITPUNKT der Meldung.
    Stream.SendManifest(source, {
        focusHash = tk.reporter and tk.reporter.hash or RPSPlayerHash(source),
        centerSec = tk.t,
        jumpT     = tk.t,
        ticketId  = id,
        me        = adminName(source),
    })

    RPSNotifySimple(source, ('~b~Meldung #%d~w~ von %s — %s'):format(
        id, tk.reporter and tk.reporter.name or '?', os.date('%H:%M:%S', tk.t)))
end

RegisterCommand('ticket_open',  openTicket, false)
RegisterCommand('incident',     openTicket, false)
RegisterCommand('rps_incident', openTicket, false)   -- Altbezeichnung

--- Status einer Meldung aus dem Menue heraus setzen.
RegisterNetEvent('d-rps:ticketStatus', function(id, status)
    local src = source
    if not RPSIsAdmin(src) then return end
    local ok = { open = true, progress = true, closed = true }
    if not ok[status] then return end
    Tickets.SetStatus(tonumber(id), status, GetPlayerName(src) or ('Admin ' .. src))
end)
