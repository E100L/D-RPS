--[[ D-RPS — server/tickets.lua
     Spielermeldungen: /ticket merkt Zeitpunkt, Ort und wer in der Naehe war;
     der Admin springt aus dem Replay-Menue dorthin. Tickets ueberleben Neustart
     (JSON neben dem Archiv, io.open — siehe archive.lua). ]]

Tickets = {}

local list   = {}      -- neueste zuletzt
local nextId = 1
local MAX    = 500

local RES = GetCurrentResourceName()

local function filePath()
    return GetResourcePath(RES):gsub('//+', '/') .. '/' .. Config.ArchivePath .. '/tickets.json'
end

-- == Persistenz ==

local function save()
    local f = io.open(filePath(), 'wb')
    if not f then return end
    f:write(json.encode({ nextId = nextId, list = list }))
    f:close()
end

local function load()
    local f = io.open(filePath(), 'rb')
    if not f then return end
    local raw = f:read('*a'); f:close()
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == 'table' and type(data.list) == 'table' then
        list   = data.list
        nextId = tonumber(data.nextId) or (#list + 1)
        print(('^2[D-RPS] %d Meldungen geladen^0'):format(#list))
    end
end

-- == Hilfen ==

local function posOf(src)
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 and DoesEntityExist(ped) then return GetEntityCoords(ped) end
    return nil
end

--- Wer war zum Meldezeitpunkt in der Naehe? Liefert dem Admin den Beteiligtenkreis ohne Namenseingabe.
local function nearbyPlayers(src, pos, radius)
    local out = {}
    if not pos then return out end
    for _, sp in ipairs(GetPlayers()) do
        local other = tonumber(sp)
        if other ~= src then
            local op = posOf(other)
            if op and #(pos - op) <= radius then
                out[#out + 1] = { id = other, hash = RPSPlayerHash(other),
                                  name = GetPlayerName(other) or ('Spieler ' .. other),
                                  dist = math.floor(#(pos - op) + 0.5) }
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- == Oeffentliche Schnittstelle ==

function Tickets.Create(src, text)
    local pos = posOf(src)
    local tk = {
        id       = nextId,
        t        = os.time(),
        -- hash zusaetzlich zur Server-ID: IDs werden nach Disconnect neu vergeben, das Pseudonym bleibt.
        reporter = { id = src, hash = RPSPlayerHash(src),
                     name = GetPlayerName(src) or ('Spieler ' .. src) },
        text     = text,
        pos      = pos and { x = pos.x, y = pos.y, z = pos.z } or nil,
        nearby   = nearbyPlayers(src, pos, Config.TicketNearbyRadius),
        status   = 'open',
    }
    nextId = nextId + 1
    list[#list + 1] = tk
    if #list > MAX then table.remove(list, 1) end
    save()

    print(('^3[D-RPS MELDUNG #%d] %s: %s^0'):format(tk.id, tk.reporter.name, text))

    -- Bestaetigung an den Melder
    RPSNotify(src, 'Meldung aufgenommen', ('Nummer #%d'):format(tk.id),
        'Ein Teammitglied schaut sich den Vorfall an.', 'CHAR_CALL911')

    -- Team benachrichtigen
    if Config.NotifyAdmins then
        local short = #text > 70 and (text:sub(1, 67) .. '...') or text
        for _, admin in ipairs(RPSAdmins()) do
            if admin ~= src then
                RPSNotify(admin, ('~y~Neue Meldung #%d'):format(tk.id), tk.reporter.name,
                    ('%s~n~~w~Oeffnen mit ~b~/ticket_open %d'):format(short, tk.id), 'CHAR_CALL911')
            end
        end
    end

    if Config.DiscordWebhook ~= '' then
        local names = {}
        for _, n in ipairs(tk.nearby) do names[#names + 1] = ('%s (%dm)'):format(n.name, n.dist) end
        PerformHttpRequest(Config.DiscordWebhook, function() end, 'POST', json.encode({
            embeds = { {
                title = ('Neue Meldung #%d'):format(tk.id),
                description = text,
                color = 16750848,
                fields = {
                    { name = 'Melder', value = tk.reporter.name, inline = true },
                    { name = 'Zeit',   value = os.date('%H:%M:%S', tk.t), inline = true },
                    { name = 'In der Naehe',
                      value = (#names > 0 and table.concat(names, ', ') or 'niemand'), inline = false },
                },
                footer = { text = ('Im Spiel oeffnen: /incident %d'):format(tk.id) },
            } },
        }), { ['Content-Type'] = 'application/json' })
    end

    return tk
end

function Tickets.All() return list end

function Tickets.Get(id)
    for _, tk in ipairs(list) do if tk.id == id then return tk end end
end

--- Status setzen (offen -> progress -> closed). Bearbeitername wird mitgefuehrt.
function Tickets.SetStatus(id, status, adminName)
    local tk = Tickets.Get(id)
    if not tk then return false end

    tk.status = status
    if status == 'progress' then
        tk.assignedTo = adminName
        tk.closedBy   = nil
    elseif status == 'closed' then
        tk.closedBy = adminName
        tk.closedAt = os.time()
    else                       -- wieder geoeffnet
        tk.assignedTo = nil
        tk.closedBy   = nil
        tk.closedAt   = nil
    end
    save()

    -- Melder auf dem Laufenden halten
    if Config.NotifyReporter and tk.reporter and tk.reporter.id then
        local rid = tk.reporter.id
        -- Nur, wenn der Melder noch derselbe Spieler auf diesem Slot ist.
        if GetPlayerName(rid) == tk.reporter.name then
            if status == 'progress' then
                RPSNotify(rid, ('Meldung #%d'):format(id), 'Wird bearbeitet',
                    ('~b~%s~w~ hat sich deiner Meldung angenommen.'):format(adminName or 'Ein Teammitglied'),
                    'CHAR_CALL911')
            elseif status == 'closed' then
                RPSNotify(rid, ('Meldung #%d'):format(id), 'Abgeschlossen',
                    '~g~Der Vorfall wurde bearbeitet.~w~ Danke fuer die Meldung.',
                    'CHAR_CALL911')
            end
        end
    end
    return true
end

-- == Befehle ==

RegisterCommand('ticket', function(source, args)
    if source == 0 then print('Der Befehl muss ingame ausgefuehrt werden'); return end

    local text = table.concat(args, ' ')
    if #text < Config.TicketMinLength then
        RPSNotify(source, 'Meldung', 'Zu kurz',
            ('Bitte beschreibe den Vorfall mit mindestens ~y~%d Zeichen~w~.'):format(Config.TicketMinLength),
            'CHAR_CALL911')
        return
    end
    if #text > Config.TicketMaxLength then
        text = text:sub(1, Config.TicketMaxLength)
    end

    -- Missbrauchsschutz: pro Spieler nur alle N Sekunden eine Meldung (Cooldown)
    local last = Tickets._last and Tickets._last[source]
    if last and (GetGameTimer() - last) < Config.TicketCooldownSeconds * 1000 then
        RPSNotify(source, 'Meldung', 'Bitte warten',
            'Du hast gerade erst gemeldet. Versuche es in einem Moment erneut.',
            'CHAR_CALL911')
        return
    end
    Tickets._last = Tickets._last or {}
    Tickets._last[source] = GetGameTimer()

    Tickets.Create(source, text)   -- bestaetigt selbst per Benachrichtigung
end, false)

--- Uebersicht in Konsole/Chat.
RegisterCommand('tickets', function(source)
    if source ~= 0 and not Config.Debug then return end
    local open = 0
    for _, tk in ipairs(list) do if tk.status == 'open' then open = open + 1 end end
    RPSReply(source, ('%d Meldungen gesamt, %d offen'):format(#list, open))
    for i = math.max(1, #list - 7), #list do
        local tk = list[i]
        RPSReply(source, ('  #%d [%s] %s: %s'):format(
            tk.id, tk.status, tk.reporter.name, tk.text:sub(1, 60)))
    end
end, false)

AddEventHandler('onResourceStart', function(res)
    if res == RES then load() end
end)

return Tickets
