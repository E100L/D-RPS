--[[ ===========================================================================
    D-RPS — Dollar Replay System
    client/notify.lua

    Rueckmeldungen ueber die native GTA-Benachrichtigung unten links.
    Farbcodes: ~g~ gruen, ~r~ rot, ~y~ gelb, ~b~ blau, ~w~ weiss.
=========================================================================== ]]

Notify = {}

--- Kurze Laufmeldung. Fuer Bestaetigungen und Hinweise.
function Notify.Simple(msg)
    if not Config.Notifications then return end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, true)
end

--- Meldung mit Absenderbild, Titel und Untertitel — fuer alles, was der
--- Empfaenger einordnen koennen muss (Meldungen, Statuswechsel).
--- @param icon  z. B. 'CHAR_CALL911', 'CHAR_DEFAULT', 'CHAR_BLOCKED'
function Notify.Advanced(title, subtitle, msg, icon)
    if not Config.Notifications then return end
    icon = icon or 'CHAR_DEFAULT'

    -- Das Bild muss geladen sein, sonst bleibt die Kachel leer.
    if not HasStreamedTextureDictLoaded(icon) then
        RequestStreamedTextureDict(icon, false)
        local tries = 0
        while not HasStreamedTextureDictLoaded(icon) and tries < 50 do
            Wait(10); tries = tries + 1
        end
    end

    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostMessagetext(icon, icon, false, 4, title, subtitle)
    EndTextCommandThefeedPostTicker(false, false)
end

--- Vom Server ausgeloeste Meldung.
RegisterNetEvent('d-rps:notify', function(kind, a, b, c, icon)
    if kind == 'simple' then
        Notify.Simple(a)
    else
        Notify.Advanced(a, b, c, icon)
    end
end)
