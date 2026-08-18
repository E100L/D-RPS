/* ===========================================================================
   D-RPS — Dollar Replay System
   ui/app.js

   Bedienlogik der Wiedergabe-Oberflaeche. Reiner Renderer: alle Zustaende
   kommen aus Lua, alle Aktionen gehen als NUI-Callback zurueck. Bewusst ohne
   Framework/Build-Schritt — NUI laesst sich ohnehin nicht escrowen (KONZEPT
   §3.10), der Wert liegt im Lua-Teil.
   =========================================================================== */

(function () {
    'use strict';

    const RES = (typeof GetParentResourceName === 'function')
        ? GetParentResourceName() : 'D-RPS';

    const el = (id) => document.getElementById(id);
    const app = el('app');

    const state = {
        open: false,
        duration: 0,
        t: 0,
        playing: true,
        speed: 1,
        focusIdx: 1,
        follow: true,
        cursor: false,
        actors: [],
        incidents: [],
        dragging: false,
    };

    // ── Hilfen ─────────────────────────────────────────────────────────────

    function post(name, data) {
        fetch(`https://${RES}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data || {}),
        }).catch(() => { /* NUI offline (Browser-Vorschau) */ });
    }

    function fmt(sec) {
        sec = Math.max(0, Math.floor(sec || 0));
        const m = Math.floor(sec / 60);
        const s = sec % 60;
        return `${m}:${String(s).padStart(2, '0')}`;
    }

    function initials(name) {
        return (name || '?').replace(/[^\p{L}\p{N} ]/gu, '')
            .split(/\s+/).filter(Boolean).slice(0, 2)
            .map((w) => w[0].toUpperCase()).join('') || '?';
    }

    const HIGH_SEVERITY = new Set(['rdm', 'vdm', 'combatlog']);
    const TYPE_LABEL = {
        rdm: 'RDM', vdm: 'VDM', combatlog: 'Combat-Log',
        spawnkill: 'Spawn-Kill', nlr: 'NLR',
    };

    // ── Rendering ──────────────────────────────────────────────────────────

    function renderPlayers() {
        const list = el('playerList');
        el('playerCount').textContent = state.actors.length;
        if (!state.actors.length) {
            list.innerHTML = '<li class="empty">Keine Aufzeichnung</li>';
            return;
        }
        list.innerHTML = '';
        state.actors.forEach((a) => {
            const li = document.createElement('li');
            li.className = 'p-item' + (a.idx === state.focusIdx ? ' is-focus' : '');
            li.innerHTML =
                `<div class="p-avatar">${initials(a.name)}</div>` +
                `<div class="p-meta">` +
                `<div class="p-name">${escapeHtml(a.name)}</div>` +
                `<div class="p-sub">${fmt(a.from)} – ${fmt(a.to)}</div>` +
                `</div>`;
            li.addEventListener('click', () => {
                state.focusIdx = a.idx;
                renderPlayers();
                post('focus', { idx: a.idx });
            });
            list.appendChild(li);
        });
    }

    function renderIncidents() {
        const list = el('incidentList');
        el('incidentCount').textContent = state.incidents.length;
        if (!state.incidents.length) {
            list.innerHTML = '<li class="empty">Keine Vorf&auml;lle erkannt</li>';
            return;
        }
        list.innerHTML = '';
        state.incidents.forEach((inc) => {
            const li = document.createElement('li');
            const high = HIGH_SEVERITY.has(inc.type) && inc.confidence >= 0.7;
            li.className = 'i-item' + (high ? ' sev-high' : '');
            li.innerHTML =
                `<div class="i-head">` +
                `<span class="i-type">${TYPE_LABEL[inc.type] || inc.type}</span>` +
                `<span class="i-conf">${Math.round((inc.confidence || 0) * 100)}%</span>` +
                `</div>` +
                `<div class="i-text">${escapeHtml(inc.summary || '')}</div>` +
                `<div class="i-time">bei ${fmt(inc.relT)}</div>`;
            li.addEventListener('click', () => seekTo(Math.max(0, inc.relT - 5)));
            list.appendChild(li);
        });
    }

    function renderMarkers() {
        const wrap = el('trackMarkers');
        wrap.innerHTML = '';
        if (!state.duration) return;
        state.incidents.forEach((inc) => {
            const m = document.createElement('div');
            const high = HIGH_SEVERITY.has(inc.type) && inc.confidence >= 0.7;
            m.className = 'marker' + (high ? ' sev-high' : '');
            m.style.left = `${(inc.relT / state.duration) * 100}%`;
            m.title = `${TYPE_LABEL[inc.type] || inc.type} — ${inc.summary || ''}`;
            m.addEventListener('click', (e) => {
                e.stopPropagation();
                seekTo(Math.max(0, inc.relT - 5));
            });
            wrap.appendChild(m);
        });
    }

    function renderProgress() {
        const pct = state.duration ? (state.t / state.duration) * 100 : 0;
        el('trackFill').style.width = `${pct}%`;
        el('trackHead').style.left = `${pct}%`;
        el('timeCur').textContent = fmt(state.t);
        el('timeTotal').textContent = fmt(state.duration);
        el('btnPlay').innerHTML = state.playing ? '&#10074;&#10074;' : '&#9654;';
        el('btnCam').textContent = state.follow ? 'Follow' : 'Freikamera';
    }

    function renderSpeed() {
        document.querySelectorAll('#speedGroup .chip').forEach((c) => {
            c.classList.toggle('is-active', parseFloat(c.dataset.v) === state.speed);
        });
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }

    // ── Aktionen ───────────────────────────────────────────────────────────

    function seekTo(t) {
        state.t = Math.max(0, Math.min(state.duration, t));
        renderProgress();
        post('seek', { t: state.t });
    }

    function trackTimeFromEvent(e) {
        const r = el('track').getBoundingClientRect();
        const f = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
        return f * state.duration;
    }

    // ── Ereignisse ─────────────────────────────────────────────────────────

    el('btnPlay').addEventListener('click', () => {
        state.playing = !state.playing;
        renderProgress();
        post('playpause');
    });
    el('btnBack').addEventListener('click', () => seekTo(state.t - 10));
    el('btnFwd').addEventListener('click', () => seekTo(state.t + 10));
    el('btnClose').addEventListener('click', () => post('close'));
    el('btnCam').addEventListener('click', () => {
        state.follow = !state.follow;
        renderProgress();
        post('camera');
    });
    el('btnCursor').addEventListener('click', () => post('cursor'));

    document.querySelectorAll('#speedGroup .chip').forEach((c) => {
        c.addEventListener('click', () => {
            state.speed = parseFloat(c.dataset.v);
            renderSpeed();
            post('speed', { v: state.speed });
        });
    });

    const track = el('track');
    track.addEventListener('mousedown', (e) => {
        state.dragging = true;
        seekTo(trackTimeFromEvent(e));
    });
    window.addEventListener('mousemove', (e) => {
        const tip = el('trackTip');
        const r = track.getBoundingClientRect();
        const inside = e.clientX >= r.left && e.clientX <= r.right
                    && e.clientY >= r.top - 6 && e.clientY <= r.bottom + 6;
        if (inside && state.duration) {
            const t = trackTimeFromEvent(e);
            tip.classList.remove('hidden');
            tip.textContent = fmt(t);
            tip.style.left = `${e.clientX - r.left}px`;
        } else {
            tip.classList.add('hidden');
        }
        if (state.dragging) seekTo(trackTimeFromEvent(e));
    });
    window.addEventListener('mouseup', () => { state.dragging = false; });

    // ── Nachrichten aus Lua ────────────────────────────────────────────────

    window.addEventListener('message', (ev) => {
        const d = ev.data || {};

        if (d.action === 'open') {
            state.open = true;
            state.duration = d.duration || 0;
            state.actors = d.actors || [];
            state.incidents = (d.incidents || []).slice().sort((a, b) => a.relT - b.relT);
            state.focusIdx = d.focusIdx || 1;
            state.t = 0; state.playing = true; state.speed = 1;

            el('sessionActors').textContent =
                `${state.actors.length} ${state.actors.length === 1 ? 'Spieler' : 'Spieler'}`;
            el('sessionDate').textContent = d.startedAt
                ? new Date(d.startedAt * 1000).toLocaleString('de-DE',
                    { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })
                : '—';

            app.classList.remove('hidden');
            renderPlayers(); renderIncidents(); renderMarkers();
            renderProgress(); renderSpeed();

        } else if (d.action === 'state') {
            if (!state.open) return;
            if (!state.dragging) state.t = d.t || 0;
            state.playing = !!d.playing;
            state.speed = d.speed || 1;
            state.cursor = !!d.cursor;
            state.follow = !!d.follow;
            if (d.focusIdx && d.focusIdx !== state.focusIdx) {
                state.focusIdx = d.focusIdx;
                renderPlayers();
            }
            el('btnCursor').textContent = state.cursor ? 'Cursor aus' : 'Cursor: M';
            renderProgress(); renderSpeed();

        } else if (d.action === 'close') {
            state.open = false;
            app.classList.add('hidden');
        }
    });

    // ESC schliesst nur den Cursor-Modus, nicht das Replay
    window.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && state.open) post('cursor');
    });
})();
