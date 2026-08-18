/* ===========================================================================
   D-RPS — ui/js/locale.js

   Sprachtabelle. Kein Text steht fest im Markup — dort nur data-i18n-Schluessel.
   Geraeteton: knapp, sachlich, ohne Entschuldigungsfloskeln. Keine Emojis.
   =========================================================================== */

export const STRINGS = {
    de: {
        'status.loading':   'Laden',
        'status.ready':     'Bereit',
        'status.playback':  'Wiedergabe',

        'hdr.recording':    'Aufzeichnung',
        'hdr.players':      'Spieler',

        'queue.title':      'Meldungen',
        'queue.hint':       'Auf eine Meldung klicken, um hinzuspringen',
        'queue.empty':      'Keine Meldungen. Spieler melden mit /ticket.',
        'ticket.by':        'Meldung von',
        'ticket.nearby':    'In der Nähe',
        'ticket.assignMe':  'Mir zuweisen',
        'ticket.close':     'Erledigt',
        'ticket.reopen':    'Wieder öffnen',
        'ticket.assignedTo':'Bearbeitet von',
        'ticket.closedBy':  'Geschlossen von',

        'players.title':    'Spieler',
        'players.empty':    'Für diesen Zeitraum liegt keine Aufzeichnung vor.',
        'players.hint':     'Auf einen Namen klicken, um zu folgen',
        'players.offline':  'ausgeloggt',

        'camera.follow':    'Folgen',
        'camera.freeHint':  'Maus schauen · WASD bewegen · ~M~ Zeiger zurückholen, dann auf Folgen klicken',
        'camera.free':      'Frei',

        'legend.title':     'Datenherkunft',
        'legend.evidence':  'Vom Server bestätigt',
        'legend.fidelity':  'Vom Client gemeldet',

        'ctx.scene':        'Szene',
        'ctx.time':         'Uhrzeit',
        'ctx.weather':      'Wetter',
        'ctx.pos':          'Position',
        'ctx.mode':         'Wiedergabe',

        'mode.playback':    'Abspielen',
        'mode.scrub':       'Bildgenau',

        'a11y.close':       'Replay beenden',
        'layout.reset':     'Ansicht zurücksetzen',
        'settings.title':      'Anzeige',
        'settings.queue':      'Meldungen',
        'settings.players':    'Spieler',
        'settings.band':       'Zeitleiste',
        'settings.hud':        'Bedienleiste',
        'settings.nametags':   'Namensschilder',
        'settings.statusbars': 'Zustandsbalken',

        'band.empty':       'Keine Aufzeichnung',
        'band.speed':       'Tempo',
        'band.absent':      'nicht auf dem Server',

        'st.open':          'Offen',
        'st.progress':      'In Arbeit',
        'st.closed':        'Geschlossen',

        'inc.rdm':          'Grundloses Töten',
        'inc.vdm':          'Anfahren',
        'inc.combatlog':    'Combat-Log',
        'inc.spawnkill':    'Spawn-Kill',
        'inc.nlr':          'Neues Leben',
    },

    en: {
        'status.loading':   'Loading',
        'status.ready':     'Ready',
        'status.playback':  'Playing',

        'hdr.recording':    'Recording',
        'hdr.players':      'players',

        'queue.title':      'Reports',
        'queue.hint':       'Click a report to jump to that moment',
        'queue.empty':      'No reports. Players submit them with /ticket.',
        'ticket.by':        'Reported by',
        'ticket.nearby':    'Nearby',
        'ticket.assignMe':  'Assign to me',
        'ticket.close':     'Resolve',
        'ticket.reopen':    'Reopen',
        'ticket.assignedTo':'Handled by',
        'ticket.closedBy':  'Closed by',

        'players.title':    'Players',
        'players.empty':    'No recording for this time range.',
        'players.hint':     'Click a name to follow that player',
        'players.offline':  'disconnected',

        'camera.follow':    'Follow',
        'camera.freeHint':  'Mouse to look · WASD to move · ~M~ brings the cursor back, then click Follow',
        'camera.free':      'Free',

        'legend.title':     'Data origin',
        'legend.evidence':  'Confirmed by server',
        'legend.fidelity':  'Reported by client',

        'ctx.scene':        'Scene',
        'ctx.time':         'Time',
        'ctx.weather':      'Weather',
        'ctx.pos':          'Position',
        'ctx.mode':         'Playback',

        'mode.playback':    'Playing',
        'mode.scrub':       'Frame accurate',

        'a11y.close':       'Close replay',
        'layout.reset':     'Reset layout',
        'settings.title':      'Display',
        'settings.queue':      'Reports',
        'settings.players':    'Players',
        'settings.band':       'Timeline',
        'settings.hud':        'Transport',
        'settings.nametags':   'Name tags',
        'settings.statusbars': 'Status bars',

        'band.empty':       'No recording',
        'band.speed':       'Speed',
        'band.absent':      'not on the server',

        'st.open':          'Open',
        'st.progress':      'In progress',
        'st.closed':        'Closed',

        'inc.rdm':          'Random deathmatch',
        'inc.vdm':          'Vehicle deathmatch',
        'inc.combatlog':    'Combat log',
        'inc.spawnkill':    'Spawn kill',
        'inc.nlr':          'New life rule',
    },
};

let current = 'de';

export function setLocale(code) {
    if (STRINGS[code]) current = code;
}

export function t(key) {
    return (STRINGS[current] && STRINGS[current][key]) || STRINGS.de[key] || key;
}

/** Alle data-i18n-Knoten im Dokument neu beschriften. */
export function applyLocale(root = document) {
    root.querySelectorAll('[data-i18n]').forEach((n) => {
        n.textContent = t(n.dataset.i18n);
    });
    root.querySelectorAll('[data-i18n-aria]').forEach((n) => {
        n.setAttribute('aria-label', t(n.dataset.i18nAria));
    });
    root.querySelectorAll('[data-i18n-title]').forEach((n) => {
        n.setAttribute('title', t(n.dataset.i18nTitle));
    });
}

/** Kurzkuerzel eines Incident-Typs fuer die Glyphe im Datenband. */
export function typeGlyph(type) {
    return ({
        rdm: 'RDM', vdm: 'VDM', combatlog: 'CL', spawnkill: 'SK', nlr: 'NLR',
    })[type] || (type || '?').slice(0, 3).toUpperCase();
}

export function typeLabel(type) {
    return t('inc.' + type) !== 'inc.' + type ? t('inc.' + type) : (type || '').toUpperCase();
}
