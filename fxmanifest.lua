fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'D-RPS'
description 'Dollar Replay System — 3D State Replay & Regelbruch-Nachvollzug'
version '0.3.0'
author 'Dollar Development'

shared_scripts {
    'shared/config.lua',
    'shared/protocol.lua',
    'shared/fidelity.lua',
}

client_scripts {
    'client/notify.lua',
    'client/reporter.lua',
    'client/fidelity.lua',
    -- nach fidelity.lua: holt die Zeitachse ueber RPSClientClock()
    'client/scene.lua',
    'client/segments.lua',
    'client/world.lua',
    'client/playback.lua',
}

server_scripts {
    'server/ringbuffer.lua',
    'server/archive.lua',
    'server/session.lua',
    'server/segindex.lua',
    'server/sessions.lua',
    'server/reporter.lua',
    'server/recorder.lua',
    'server/vehicles.lua',
    'server/interactions.lua',
    'server/events.lua',
    'server/detection.lua',
    'server/tickets.lua',
    'server/scene.lua',
    'server/stream.lua',
    'server/replay.lua',
    'server/main.lua',
}

ui_page 'ui/index.html'

files {
    'ui/index.html',
    'ui/css/*.css',
    'ui/js/*.js',
}

-- Nur die Config ist buyer-editierbar; NUI kann ohnehin nicht escrowed werden.
escrow_ignore {
    'shared/config.lua',
}
