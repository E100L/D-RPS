/* ===========================================================================
   D-RPS — ui/js/main.js

   Steuerung der Oberflaeche. Reiner Renderer: Zustand kommt per postMessage
   aus dem Client-Lua, Aktionen gehen als fetch-Callback zurueck. Keine
   Detection- oder Formatlogik hier — die NUI liegt beim Kunden im Klartext
   (nicht escrow-faehig), der Wert sitzt im Lua-Teil.
   =========================================================================== */

import { applyLocale, setLocale, t, typeLabel } from './locale.js';
import { Timeline, fmtTimecode } from './timeline.js';
import { makeFloating, resetLayout } from './windows.js';

const RES = (typeof GetParentResourceName === 'function')
    ? GetParentResourceName() : 'D-RPS';

const $  = (sel, r = document) => r.querySelector(sel);
const $b = (name) => document.querySelector(`[data-bind="${name}"]`);

const root = $('#rps');

const S = {
    open: false, duration: 0, t: 0, playing: true, rate: 1,
    follow: true, cursor: false, scrub: false,
    actors: [], incidents: [], focusIdx: 1, activeIncident: null, me: '?',
    shuttle: 0,
};

let timeline = null;

/* ── Anzeige-Einstellungen ────────────────────────────────────────────────
   Was der Admin gerade sehen will, entscheidet er selbst. Die Auswahl bleibt
   ueber die Sitzung hinaus erhalten. Die beiden 3D-Schalter (Namensschilder,
   Zustandsbalken) reicht die Oberflaeche an die Spielseite weiter. */
const VIEW_STORE = 'drps.view.v1';
const view = Object.assign(
    { queue: true, players: true, band: true, hud: true, nametags: true, statusbars: true },
    (() => { try { return JSON.parse(localStorage.getItem(VIEW_STORE) || '{}'); }
             catch { return {}; } })());

function applyView() {
    const show = (sel, on) => {
        const el = document.querySelector(sel);
        if (el) el.style.display = on ? '' : 'none';
    };
    show('.pane-l', view.queue);
    show('.pane-r', view.players);
    show('.tl',     view.band);
    show('.hud',    view.hud);
    document.querySelectorAll('[data-set]').forEach((cb) => { cb.checked = !!view[cb.dataset.set]; });
    post('view', { nametags: view.nametags, statusbars: view.statusbars });
    if (view.band && timeline) requestAnimationFrame(() => timeline.refresh());
    try { localStorage.setItem(VIEW_STORE, JSON.stringify(view)); } catch { /* egal */ }
}

/* ── Bruecke zu Lua ──────────────────────────────────────────────────────── */

function post(name, data) {
    fetch(`https://${RES}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {}),
    }).catch(() => { /* ausserhalb der NUI (Vorschau im Browser) */ });
}

/* ── Formatierung ────────────────────────────────────────────────────────── */

const esc = (s) => String(s ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function fmtClock(sec) {
    const m = Math.floor(sec / 60), s = Math.floor(sec % 60);
    return `${m}:${String(s).padStart(2, '0')}`;
}

function initials(name) {
    return String(name || '?').replace(/[^\p{L}\p{N} ]/gu, '')
        .split(/\s+/).filter(Boolean).slice(0, 2)
        .map((w) => w[0].toUpperCase()).join('') || '?';
}

/* ── Panels ──────────────────────────────────────────────────────────────── */

function renderQueue() {
    const host = $b('queueList');
    $b('queueCount').textContent = S.incidents.length;

    if (!S.incidents.length) {
        host.innerHTML = `<div class="empty">${esc(t('queue.empty'))}</div>`;
        return;
    }
    host.innerHTML = S.incidents.map((inc) => {
        const isAuto = !!inc.auto;
        const status = inc.status || 'open';
        const head = isAuto ? typeLabel(inc.type) : `${t('ticket.by')} ${inc.reporter || '?'}`;
        const body = isAuto ? (inc.summary || '') : (inc.text || '');

        const meta = [];
        if (!isAuto && inc.nearby && inc.nearby.length) {
            meta.push(`${t('ticket.nearby')}: ${esc(inc.nearby.slice(0, 3).join(', '))}`);
        }
        if (status === 'progress' && inc.assignedTo) {
            meta.push(`${t('ticket.assignedTo')}: ${esc(inc.assignedTo)}`);
        }
        if (status === 'closed' && inc.closedBy) {
            meta.push(`${t('ticket.closedBy')}: ${esc(inc.closedBy)}`);
        }

        /* Knoepfe folgen dem Ablauf: offen → zuweisen → erledigt.
           Eine geschlossene Meldung laesst sich wieder oeffnen. */
        let actions = '';
        if (!isAuto) {
            const btns = [];
            if (status === 'open') {
                btns.push(`<button class="q-btn q-btn-p" data-act-tk="progress" data-key="${inc.key}">${esc(t('ticket.assignMe'))}</button>`);
            }
            if (status !== 'closed') {
                btns.push(`<button class="q-btn" data-act-tk="closed" data-key="${inc.key}">${esc(t('ticket.close'))}</button>`);
            } else {
                btns.push(`<button class="q-btn" data-act-tk="open" data-key="${inc.key}">${esc(t('ticket.reopen'))}</button>`);
            }
            actions = `<div class="q-actions">${btns.join('')}</div>`;
        }

        return `
        <div class="q${inc.key === S.activeIncident ? ' is-active' : ''}" data-inc="${inc.key}">
          <div class="q-row">
            <span class="q-t">${esc(head)}</span>
            <span class="q-s" data-s="${status}">${esc(t('st.' + status))}</span>
          </div>
          <div class="q-d">${esc(body)}</div>
          ${meta.map((m) => `<div class="q-near">${m}</div>`).join('')}
          <div class="q-m"><span>${fmtClock(inc.relT)}</span><span>#${inc.id}</span></div>
          ${actions}
        </div>`;
    }).join('');

    host.querySelectorAll('.q').forEach((n) => {
        n.addEventListener('click', () => jumpToIncident(n.dataset.inc));
    });
    host.querySelectorAll('[data-act-tk]').forEach((b) => {
        b.addEventListener('click', (e) => {
            e.stopPropagation();
            const key = b.dataset.key;
            const next = b.dataset.actTk;
            const inc = S.incidents.find((i) => i.key === key);
            if (!inc) return;
            inc.status = next;
            if (next === 'progress') { inc.assignedTo = S.me; inc.closedBy = null; }
            else if (next === 'closed') { inc.closedBy = S.me; }
            else { inc.assignedTo = null; inc.closedBy = null; }
            post('ticketStatus', { key, status: next });
            renderQueue();
            timeline.invalidateStatic();
        });
    });
}

/* Unterzeile eines Spielers. Seit die Spielerliste aus dem Sitzungs-Index
   kommt, koennen hier auch Ausgeloggte stehen — die haben keine Server-ID
   mehr, und ihr Zeitraum endet vor dem Ende der Aufzeichnung. */
function playerSub(a) {
    const span = `${fmtClock(a.from)}–${fmtClock(a.to)}`;
    if (a.online === false) return `${t('players.offline')} · ${span}`;
    return `${a.id ?? '—'} · ${span}`;
}

function renderPlayers() {
    const host = $b('playerList');
    $b('playerCount').textContent = S.actors.length;

    if (!S.actors.length) {
        host.innerHTML = `<div class="empty">${esc(t('players.empty'))}</div>`;
        return;
    }
    const CAR = '<svg viewBox="0 0 16 16" aria-hidden="true">' +
        '<path d="M2.4 10.5h11.2M3.6 10.5V12M12.4 10.5V12"/>' +
        '<path d="M3 10.2l1-3.4a1.4 1.4 0 0 1 1.3-1h5.4a1.4 1.4 0 0 1 1.3 1l1 3.4"/></svg>';
    const EYE = '<svg viewBox="0 0 16 16" aria-hidden="true">' +
        '<path d="M1.6 8s2.5-4.2 6.4-4.2S14.4 8 14.4 8s-2.5 4.2-6.4 4.2S1.6 8 1.6 8z"/>' +
        '<circle cx="8" cy="8" r="1.9"/></svg>';

    host.innerHTML = S.actors.map((a) => {
        const hp = Math.max(0, Math.min(100, ((a.health ?? 200) - 100)));
        const dead = (a.health ?? 200) <= 100 ? 1 : 0;
        return `
        <div class="p${a.idx === S.focusIdx ? ' is-active' : ''}" data-idx="${a.idx}">
          <span class="p-av">${esc(initials(a.name))}</span>
          <span style="min-width:0">
            <span class="p-n">${esc(a.name)}</span>
            <span class="p-sub">${esc(playerSub(a))}</span>
          </span>
          <span class="p-st">
            ${a.veh ? `<span class="p-veh">${CAR}</span>` : ''}
            <span class="p-hp" data-dead="${dead}"><i style="width:${dead ? 100 : hp}%"></i></span>
            ${a.idx === S.focusIdx ? `<span class="p-eye">${EYE}</span>` : ''}
          </span>
        </div>`;
    }).join('');

    host.querySelectorAll('.p').forEach((n) => {
        n.addEventListener('click', () => {
            S.focusIdx = Number(n.dataset.idx);
            renderPlayers();
            post('focus', { idx: S.focusIdx });
        });
    });
}

/* ── Kopfzeile / Zustand ─────────────────────────────────────────────────── */

function renderClock() {
    $b('timecode').textContent = fmtTimecode(S.t);
    $b('timecodeTotal').textContent = fmtTimecode(S.duration);
}

const RATES = [0.25, 0.5, 1, 2, 4];
const PLAY_PATH  = 'M4.5 3l8 5-8 5z';
const PAUSE_PATH = 'M5 3h2.2v10H5zM8.8 3H11v10H8.8z';

function renderTransport() {
    $b('playGlyph').innerHTML =
        `<path d="${S.playing ? PAUSE_PATH : PLAY_PATH}" class="fill"/>`;

    $b('rateVal').textContent = String(S.rate).replace('.', ',') + '×';
    const slider = $b('rateSlider');
    const idx = RATES.indexOf(S.rate);
    if (idx >= 0 && Number(slider.value) !== idx) slider.value = String(idx);

    document.querySelectorAll('[data-act="shuttle"]').forEach((b) => {
        b.classList.toggle('is-on', Number(b.dataset.v) === S.shuttle && S.shuttle !== 0);
    });
    document.querySelectorAll('[data-act="cam"]').forEach((b) => {
        b.classList.toggle('is-on', (b.dataset.v === 'follow') === S.follow);
    });
    $b('cursorBtn').classList.toggle('is-on', S.cursor);

    // Bei Freikamera erklaeren, wie man den Zeiger zurueckholt.
    const fh = $b('camFreeHint');
    fh.hidden = S.follow;
    if (!S.follow) {
        // Der Platzhalter ~M~ wird als Tastensymbol gesetzt; der Text stammt aus
        // der eigenen Sprachtabelle, nicht von aussen.
        fh.innerHTML = esc(t('camera.freeHint')).replace('~M~', '<kbd>M</kbd>');
    }

    const tally = $b('tally');
    const state = S.playing ? 'playback' : 'ready';
    tally.dataset.state = state;
    tally.lastElementChild.textContent = t('status.' + state);

    $b('modeLabel').textContent = t(S.scrub ? 'mode.scrub' : 'mode.playback');
}

/* ── Aktionen ────────────────────────────────────────────────────────────── */

function seek(time, fromUser = true) {
    S.t = Math.max(0, Math.min(S.duration, time));
    renderClock();
    timeline && timeline.setTime(S.t);
    if (fromUser) post('seek', { t: S.t });
}

function jumpToIncident(key) {
    const inc = S.incidents.find((i) => i.key === key);
    if (!inc) return;
    S.activeIncident = key;
    renderQueue();
    timeline && timeline.setActive(key);
    seek(Math.max(0, inc.relT - 5));
    post('incidentFocus', { key });
}

/* J/K/L-Logik: mehrfaches Druecken erhoeht die Stufe. */
function shuttle(dir) {
    if (dir === 0) { S.shuttle = 0; S.rate = 1; post('shuttle', { dir: 0, rate: 1 }); }
    else if (S.shuttle === dir) { S.rate = Math.min(8, S.rate * 2); post('shuttle', { dir, rate: S.rate }); }
    else { S.shuttle = dir; S.rate = 2; post('shuttle', { dir, rate: 2 }); }
    renderTransport();
}

function setRate(v) {
    S.rate = v; S.shuttle = 0;
    post('rate', { v });
    renderTransport();
}

/* ── Bedienelemente ──────────────────────────────────────────────────────── */

document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const act = b.dataset.act;

    if (act === 'close')      post('close');
    else if (act === 'playpause') { S.playing = !S.playing; renderTransport(); post('playpause'); }
    else if (act === 'step')  post('step', { dir: Number(b.dataset.v) });
    else if (act === 'shuttle') shuttle(Number(b.dataset.v));
    else if (act === 'cam')   { S.follow = b.dataset.v === 'follow'; renderTransport(); post('camera', { follow: S.follow }); }
    else if (act === 'cursor') post('cursor');
    else if (act === 'resetLayout') { resetLayout(); timeline.invalidateStatic(); }
    else if (act === 'toggleSettings') {
        const p = $b('settingsPop');
        p.hidden = !p.hidden;
    }
});
document.querySelectorAll('[data-set]').forEach((cb) => {
    cb.addEventListener('change', () => { view[cb.dataset.set] = cb.checked; applyView(); });
});

/* Klick ausserhalb schliesst das Klappfenster. */
document.addEventListener('mousedown', (e) => {
    const p = $b('settingsPop');
    if (!p.hidden && !e.target.closest('.pop-wrap')) p.hidden = true;
});

/* Tempo-Regler: rastet auf die fuenf gebraeuchlichen Stufen ein. */
$b('rateSlider').addEventListener('input', (e) => {
    setRate(RATES[Number(e.target.value)] ?? 1);
});

/* Tastatur: BEWUSST NICHT hier.
   Solange die Oberflaeche den Zeiger fuehrt, bekommt sie auch Tastenanschlaege.
   Einzelbuchstaben-Kuerzel wuerden dann beim Tippen im Spielchat ausloesen —
   ein getipptes "/replay" enthaelt l und e und haette Shuttle und
   Vorfallwechsel gestartet. Alle Tasten wertet deshalb die Spielseite aus
   (client/playback.lua); dort ist der Chat-Zustand bekannt.
   Ausnahme: Escape schliesst den Zeigermodus. */
window.addEventListener('keydown', (e) => {
    if (S.open && e.key === 'Escape') post('cursor');
});

/* ── Nachrichten aus Lua ─────────────────────────────────────────────────── */

window.addEventListener('message', (ev) => {
    const d = ev.data || {};

    if (d.action === 'open') {
        if (d.locale) setLocale(d.locale);
        applyLocale();

        S.open = true;
        S.duration  = d.duration || 0;
        S.actors    = d.actors || [];
        S.incidents = (d.incidents || []).slice().sort((a, b) => a.relT - b.relT);
        S.focusIdx  = d.focusIdx || 1;
        S.t = 0; S.playing = true; S.rate = 1; S.shuttle = 0;
        S.activeIncident = d.activeIncident || null;
        S.me = d.me || '?';

        /* Kopfzeile aus den Rohzeitstempeln bilden. Lua liefert nur Unix-
           Sekunden — clientseitig steht dort kein os zur Verfuegung. */
        const loc = (d.locale === 'en') ? 'en-GB' : 'de-DE';
        if (d.startedAt) {
            const a = new Date(d.startedAt * 1000);
            const b = new Date((d.endedAt || d.startedAt) * 1000);
            const hm = { hour: '2-digit', minute: '2-digit', second: '2-digit' };
            $b('ctxTitle').textContent = `${t('hdr.recording')} ${a.toLocaleDateString(loc,
                { day: '2-digit', month: 'long', year: 'numeric' })}`;
            $b('ctxSub').textContent = `${a.toLocaleTimeString(loc, hm)} – ` +
                `${b.toLocaleTimeString(loc, hm)} · ${S.actors.length} ${t('hdr.players')}`;
        } else {
            $b('ctxTitle').textContent = d.title || '—';
            $b('ctxSub').textContent   = d.subtitle || '';
        }

        timeline.setData({
            duration: S.duration,
            incidents: S.incidents,
            events: d.events || [],
            telemetry: d.telemetry || [],
            gaps: d.gaps || [],
        });
        timeline.setActive(S.activeIncident);

        renderQueue(); renderPlayers(); renderClock(); renderTransport();
        root.dataset.open = 'true';
        applyView();

        // Erst nach dem Einblenden hat der Behaelter wieder eine Groesse.
        requestAnimationFrame(() => requestAnimationFrame(() => timeline.refresh()));

        /* Ein einzelner Tally-Blink, wenn der Stream steht. */
        const tally = $b('tally');
        tally.classList.remove('is-blink');
        void tally.offsetWidth;
        tally.classList.add('is-blink');

        if (d.jumpTo != null) seek(d.jumpTo, false);

    } else if (d.action === 'state') {
        if (!S.open) return;
        if (!timeline.dragging) { S.t = d.t || 0; renderClock(); timeline.setTime(S.t); }
        S.playing = !!d.playing;
        S.rate    = d.rate || 1;
        S.follow  = !!d.follow;
        S.cursor  = !!d.cursor;
        S.scrub   = !!d.scrub;
        if (d.focusIdx && d.focusIdx !== S.focusIdx) { S.focusIdx = d.focusIdx; renderPlayers(); }
        if (d.activeIncident !== undefined && d.activeIncident !== S.activeIncident) {
            S.activeIncident = d.activeIncident;
            renderQueue();
            timeline.setActive(S.activeIncident);
        }
        if (d.pos)     $b('scenePos').textContent = d.pos;
        if (d.clock)   $b('sceneTime').textContent = d.clock;
        if (d.weather) $b('sceneWeather').textContent = d.weather;
        renderTransport();

    } else if (d.action === 'telemetry') {
        timeline.setTelemetry(d.series || [], d.events || [], d.gaps || []);

    } else if (d.action === 'close') {
        S.open = false;
        root.dataset.open = 'false';
    }
});

/* ── Start ───────────────────────────────────────────────────────────────── */

applyLocale();

/* Alle Flaechen frei platzierbar. Die Panels zieht man an ihrer Kopfzeile,
   die Transportkapsel an ihrem Rand, das Datenband laesst sich in der Hoehe
   verstellen. Die Anordnung bleibt ueber die Sitzung hinaus erhalten. */
makeFloating($('.pane-l'), { key: 'queue',   handle: $('.pane-l .pane-hd'), minW: 200, minH: 140 });
makeFloating($('.pane-r'), { key: 'players', handle: $('.pane-r .pane-hd'), minW: 200, minH: 160 });
makeFloating($('.hud'),    { key: 'hud',     resize: 'none' });

timeline = new Timeline($('#bandStatic'), $('#bandLive'), $('#band'), {
    onSeek: (time) => seek(time),
    onIncident: (inc) => jumpToIncident(inc.key),
    onHover: (h) => {
        const tip = $b('bandTip');
        if (!h) { tip.hidden = true; return; }
        tip.hidden = false;
        /* Der Hinweis haengt jetzt an der Bedienleiste, nicht mehr im Band.
           Deshalb den Bandversatz aufschlagen — und ihn oberhalb der Bandkante
           setzen, wo er frueher vom overflow:hidden abgeschnitten wurde. */
        const band = document.getElementById('band');
        tip.style.left = (band.offsetLeft + h.x) + 'px';
        tip.style.top  = (band.offsetTop - 6) + 'px';
        tip.textContent = h.inc
            ? `${typeLabel(h.inc.type)} · ${Math.round((h.inc.confidence || 0) * 100)}%`
            : fmtTimecode(h.t);
    },
});

makeFloating(document.getElementById('band'), {
    key: 'band', resize: 'y', minH: 44, draggable: false,
    onResize: () => timeline && timeline.invalidateStatic(),
});
