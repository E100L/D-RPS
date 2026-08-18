--[[ D-RPS — server/main.lua
     Initialisierung, Spieler-Lebenszyklus und Admin/DSGVO-Commands. ]]

local function log(msg) print(('^5[D-RPS]^0 %s'):format(msg)) end

-- ── Start ──────────────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    log(('D-RPS v%s startet …'):format(GetResourceMetadata(res, 'version', 0)))
    log(('OneSync: %s | Build: %s'):format(
        GetConvar('onesync', '?'), GetConvar('sv_enforceGameBuild', '?')))

    -- Reihenfolge zwingend: Archive zuerst (setzt DiskArchive=false bei nicht
    -- beschreibbarem Ordner), Session vor SegIndex (Segmentnummer braucht Zeitachse).
    Archive.Init()       -- Pfad, Schreibbarkeit, Loeschfaehigkeit
    Session.Init()       -- Zeitachse: Epoche und Segmentraster
    SegIndex.Init()      -- Offset-Index ueber die Tagesarchive
    SessionIndex.Init()  -- wer war wann online (auch die Ausgeloggten)

    Recording = true

    -- Bereits verbundene Spieler aufnehmen (Resource-Restart im laufenden Betrieb)
    for _, src in ipairs(GetPlayers()) do
        Recorder.StartPlayer(tonumber(src))
    end
    log('Recording aktiv.')

    -- Hinweis, wenn nirgends eine Berechtigung vergeben ist (sonst kann niemand
    -- ein Replay oeffnen, faellt erst im Ernstfall auf).
    if type(Config.AdminIdentifiers) ~= 'table' or #Config.AdminIdentifiers == 0 then
        if not IsPrincipalAceAllowed('group.admin', Config.AdminAce) then
            print('^3[D-RPS] Hinweis: Fuer "' .. Config.AdminAce .. '" ist keine Gruppe freigeschaltet.^0')
            print('^3        In die server.cfg aufnehmen:  add_ace group.admin ' .. Config.AdminAce .. ' allow^0')
            print('^3        Alternativ Config.AdminIdentifiers in shared/config.lua fuellen.^0')
        end
    end
end)

-- == Retention ==
-- DSGVO-Zusage aus Config.RetentionDays. Stuendlich plus einmal kurz nach Start.

CreateThread(function()
    Wait(60000)
    while true do
        if Config.DiskArchive and Config.RetentionDays > 0 then
            local hashes = SessionIndex.KnownHashes()
            -- Weltspur mit unter die Frist: sie steht unter keinem Pseudonym und
            -- faellt sonst aus KnownHashes heraus.
            hashes[Protocol.WORLD_HASH] = true
            local removed = Archive.Purge(hashes)
            if removed > 0 then
                log(('Retention: %d Archivdatei(en) aelter als %d Tage geloescht.')
                    :format(removed, Config.RetentionDays))
            end
        end
        Wait(3600000)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- Offene Chunks sichern, bevor die Resource verschwindet (onStop-Flush).
    for _, src in ipairs(GetPlayers()) do
        Recorder.StopPlayer(tonumber(src))
    end
    -- Weltspur haengt an keinem Spieler; sonst bliebe ihr letztes Segment liegen.
    if WorldVeh then WorldVeh.FlushAll() end
    log('Recording gestoppt, offene Chunks gesichert.')
end)

-- == Spieler-Lebenszyklus ==
-- Stop bei Drop; Start ueber Reconcile-Thread, sobald der Ped existiert.
-- Framework-unabhaengig (Standalone).

AddEventHandler('playerDropped', function()
    local src = source
    Recorder.StopPlayer(src)
end)

--- Zeitachse an einen Client schicken. Ohne sie schliesst der Client Chunks
--- nach eigener Uhr, jeder deckt zwei Segmente -> Ein-Segment-Regel verletzt.
local function sendSession(src)
    if not (Session and Session.Epoch) then return end
    TriggerClientEvent('d-rps:session', src,
        Session.Epoch(), Session.SegSeconds(), os.time())
end

CreateThread(function()
    while true do
        Wait(2000)
        if Recording then
            for _, sp in ipairs(GetPlayers()) do
                local src = tonumber(sp)
                local ped = GetPlayerPed(src)
                if ped and ped ~= 0 and DoesEntityExist(ped) then
                    if not Recorder.HashOf(src) then sendSession(src) end
                    Recorder.StartPlayer(src)   -- idempotent
                end
            end
        end
    end
end)

-- == Commands ==
-- Antwort geht an ausfuehrenden Spieler (Chat) UND Konsole.

-- Global, damit auch andere Servermodule im Chat antworten koennen.
function RPSReply(src, msg)
    print(('^5[D-RPS]^0 %s'):format(msg))
    if src and src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '^5[D-RPS]', msg } })
    end
end
local reply = RPSReply

--- Native GTA-Benachrichtigung an einen Spieler.
--- RPSNotify(src, 'Titel', 'Untertitel', 'Text', 'CHAR_...')
function RPSNotify(src, title, subtitle, msg, icon)
    if not src or src == 0 then return end
    TriggerClientEvent('d-rps:notify', src, 'advanced', title, subtitle, msg, icon)
end

--- Kurze Laufmeldung ohne Bild.
function RPSNotifySimple(src, msg)
    if not src or src == 0 then return end
    TriggerClientEvent('d-rps:notify', src, 'simple', msg)
end

--- Darf dieser Spieler Team-Funktionen nutzen? Zwei Wege: ACE aus Config.AdminAce
--- oder Eintrag in Config.AdminIdentifiers. Config.Debug oeffnet bewusst NICHTS.
function RPSIsAdmin(src)
    if not src or src == 0 then return false end
    if IsPlayerAceAllowed(src, Config.AdminAce) then return true end

    local allow = Config.AdminIdentifiers
    if type(allow) ~= 'table' or #allow == 0 then return false end
    local want = {}
    for _, id in ipairs(allow) do want[tostring(id):lower()] = true end
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if want[tostring(id):lower()] then return true end
    end
    return false
end

--- Alle Team-Mitglieder, die gerade online sind.
function RPSAdmins()
    local out = {}
    for _, sp in ipairs(GetPlayers()) do
        local s = tonumber(sp)
        if RPSIsAdmin(s) then out[#out + 1] = s end
    end
    return out
end

--- Diagnose-Commands: Debug-Modus UND Berechtigung. Konsole (source==0) immer.
local function mayDiagnose(src)
    if not Config.Debug then return false end
    return src == 0 or RPSIsAdmin(src)
end

-- Diagnose-Logger: schreibt nach D-RPS/diag.log. Nur Debug.
function RPSDiag(msg)
    if not Config.Debug then return end
    local p = GetResourcePath(GetCurrentResourceName()):gsub('//+', '/') .. '/diag.log'
    local f = io.open(p, 'ab')
    if f then f:write(('%s %s\n'):format(os.date('%H:%M:%S'), msg)); f:close() end
end

RegisterCommand('rps_stats', function(source)
    if not mayDiagnose(source) then return end
    local s = Recorder.Stats()
    reply(source, ('Stats: %d Spieler, %d Chunks im RAM, %.1f KB'):format(
        s.players, s.ramChunks, s.ramBytes / 1024.0))
end, false)

-- Zeigt dem Aufrufer seine eigenen Identifier und Berechtigung; die Ausgabezeile
-- kommt direkt in die server.cfg. Jeder darf das (nur eigene Angaben).
RegisterCommand('rps_whoami', function(source)
    if source == 0 then print('Der Befehl muss ingame ausgefuehrt werden'); return end
    reply(source, ('Berechtigt: %s'):format(RPSIsAdmin(source) and '^2ja^0' or '^1nein^0'))
    for _, id in ipairs(GetPlayerIdentifiers(source) or {}) do
        if id:sub(1, 8) == 'license:' then
            reply(source, ('add_ace identifier.%s %s allow'):format(id, Config.AdminAce))
        end
    end
end, false)

-- Wer war in den letzten N Minuten aufgezeichnet? Auch inzwischen offline (Sinn
-- des Sitzungs-Index).
RegisterCommand('rps_sessions', function(source, args)
    if not mayDiagnose(source) then return end
    local mins = math.max(1, tonumber(args and args[1] or nil) or Config.ReplayWindowMinutes)
    local now  = os.time()
    local list = SessionIndex.Query(now - mins * 60, now)
    reply(source, ('Sitzungen der letzten %d Minuten: %d'):format(mins, #list))
    for i = 1, math.min(#list, 20) do
        local e = list[i]
        reply(source, ('  %s %s [%08x]  %s–%s  (%d Abschnitt(e))'):format(
            e.online and '^2online^0' or '^3offline^0',
            e.name or '?', e.hash,
            os.date('%H:%M:%S', e.from), os.date('%H:%M:%S', e.to), #e.spans))
    end
end, false)

-- Loeschverlangen nach Art. 17 DSGVO. Erst anzeigen, dann mit "bestaetigen"
-- ausfuehren — die Loeschung ist endgueltig.
RegisterCommand('rps_forget', function(source, args)
    if source ~= 0 and not RPSIsAdmin(source) then return end
    local who = args and args[1]
    if not who then
        reply(source, 'Nutzung: /rps_forget <license:… | 8-stelliger Hash> [bestaetigen]')
        return
    end

    -- Identifier wird gehasht, Pseudonym direkt uebernommen (die license steht
    -- nirgends im Archiv).
    local hash
    if who:find(':', 1, true) then
        hash = RPSHashOfIdentifier(who)
    else
        hash = tonumber(who, 16)
    end
    if not hash then reply(source, 'Kein gueltiger Identifier oder Hash.'); return end
    hash = hash & 0xFFFFFFFF

    if args[2] ~= 'bestaetigen' then
        reply(source, ('Loescht ALLE Aufzeichnungen zu Pseudonym %08x (%s).')
            :format(hash, SessionIndex.NameOf(hash) or 'Name unbekannt'))
        reply(source, ('Zum Ausfuehren: /rps_forget %s bestaetigen'):format(who))
        return
    end

    local n = SessionIndex.Forget(hash)
    reply(source, ('Geloescht: %d Datei(en) zu Pseudonym %08x.'):format(n, hash))
end, false)
