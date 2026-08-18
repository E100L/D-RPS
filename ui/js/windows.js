/* ===========================================================================
   D-RPS — ui/js/windows.js

   Macht Bedienflaechen verschiebbar und in der Groesse verstellbar.

   Ein Admin arbeitet mit zwei Bildschirmhaelften gleichzeitig: der Szene und
   dem Werkzeug. Wo die Panels stehen duerfen, muss er selbst entscheiden —
   je nachdem, wo im Bild gerade das Geschehen ist.

   Die Anordnung wird im Browserspeicher gehalten und ueberdauert damit die
   Sitzung. "Ansicht zuruecksetzen" stellt den Auslieferungszustand her.
   =========================================================================== */

const STORE = 'drps.layout.v1';
const MARGIN = 6;                 /* Mindestabstand zum Bildrand */

let layout = {};
const registry = [];

/* ── Speicher ───────────────────────────────────────────────────────────── */

function loadLayout() {
    try { layout = JSON.parse(localStorage.getItem(STORE) || '{}') || {}; }
    catch { layout = {}; }
}

function saveLayout() {
    try { localStorage.setItem(STORE, JSON.stringify(layout)); } catch { /* egal */ }
}

loadLayout();

/* ── Hilfen ─────────────────────────────────────────────────────────────── */

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

/** Element auf absolute Koordinaten umstellen (weg von right/transform).
    Die Werte sind Bildschirmkoordinaten — sie muessen auf den Bezugsrahmen
    umgerechnet werden, sonst springt ein Element, dessen Elternflaeche nicht
    am Bildursprung liegt. */
function pinToRect(el, rect) {
    const par = el.offsetParent;
    const p = par ? par.getBoundingClientRect() : { left: 0, top: 0 };
    el.style.left      = (rect.left - p.left) + 'px';
    el.style.top       = (rect.top - p.top) + 'px';
    el.style.right     = 'auto';
    el.style.bottom    = 'auto';
    el.style.transform = 'none';
    el.style.margin    = '0';
}

function applyStored(el, key, opts) {
    const s = layout[key];
    if (!s) return false;
    // Eine unsinnig gespeicherte Groesse wird verworfen, statt die Flaeche
    // unbedienbar zu machen.
    if (s.h !== undefined && (s.h < opts.minH || s.h > window.innerHeight)) return false;
    const w = window.innerWidth, h = window.innerHeight;
    const width  = s.w ? clamp(s.w, opts.minW, w - MARGIN * 2) : el.offsetWidth;
    const height = s.h ? clamp(s.h, opts.minH, h - MARGIN * 2) : el.offsetHeight;
    // Breite nur zurueckspielen, wenn sie auch verstellbar ist. Beim Datenband
    // ('y') ist sie das nicht: es soll ueber die volle Breite laufen. Eine
    // einmal gespeicherte Pixelbreite haette es dauerhaft schmal gemacht.
    if (s.w && opts.resize === 'both') el.style.width = width + 'px';
    if (s.h && opts.resize !== 'none') {
        el.style.height = height + 'px';
        el.style.maxHeight = 'none';
        el.dataset.userSized = '1';      // gespeicherte Hoehe hat Vorrang
    }
    if (opts.resize !== 'y') {
        pinToRect(el, {
            left: clamp(s.x, MARGIN, Math.max(MARGIN, w - width - MARGIN)),
            top:  clamp(s.y, MARGIN, Math.max(MARGIN, h - height - MARGIN)),
        });
    }
    return true;
}

function store(el, key, opts) {
    const r = el.getBoundingClientRect();
    layout[key] = { x: opts.resize === 'y' ? undefined : Math.round(r.left),
                    y: opts.resize === 'y' ? undefined : Math.round(r.top),
                    w: opts.resize === 'both' ? Math.round(r.width) : undefined,
                    h: (opts.resize === 'none' || opts.resize === 'x') ? undefined : Math.round(r.height) };
    saveLayout();
}

/* ── Verschieben und Groesse aendern ────────────────────────────────────── */

/**
 * @param el      zu bewegendes Element
 * @param opts.key      Speicherschluessel
 * @param opts.handle   Element, an dem gezogen wird (Standard: el)
 * @param opts.resize   'both' | 'y' | 'none'
 * @param opts.minW/minH Mindestmasse
 */
export function makeFloating(el, opts = {}) {
    const o = Object.assign({ resize: 'both', minW: 180, minH: 120,
                             handle: el, draggable: true }, opts);
    registry.push({ el, o });

    el.classList.add('flt');
    applyStored(el, o.key, o);

    /* Ziehen am Griff — entfaellt, wenn die Flaeche selbst eine Bedienflaeche
       ist. Das Datenband etwa dient dem Spulen; ein Ziehgriff darauf wuerde
       jeden Klick zum Verschieben machen. */
    if (o.draggable) {
        o.handle.classList.add('flt-handle');
        o.handle.addEventListener('mousedown', (e) => {
            /* Klicks auf Bedienelemente im Griff nicht abfangen */
            if (e.target.closest('button, input, a, .q, .p')) return;
            e.preventDefault();

            const r = el.getBoundingClientRect();
            pinToRect(el, r);
            const dx = e.clientX - r.left, dy = e.clientY - r.top;
            el.classList.add('is-moving');

            const move = (ev) => {
                const w = el.offsetWidth, h = el.offsetHeight;
                el.style.left = clamp(ev.clientX - dx, MARGIN, window.innerWidth  - w - MARGIN) + 'px';
                el.style.top  = clamp(ev.clientY - dy, MARGIN, window.innerHeight - h - MARGIN) + 'px';
            };
            const up = () => {
                window.removeEventListener('mousemove', move);
                window.removeEventListener('mouseup', up);
                el.classList.remove('is-moving');
                store(el, o.key, o);
            };
            window.addEventListener('mousemove', move);
            window.addEventListener('mouseup', up);
        });
    }

    /* Groesse aendern */
    if (o.resize !== 'none') {
        const grip = document.createElement('div');
        grip.className = 'flt-grip flt-grip-' + o.resize;
        grip.setAttribute('aria-hidden', 'true');
        el.appendChild(grip);

        grip.addEventListener('mousedown', (e) => {
            e.preventDefault(); e.stopPropagation();
            const r = el.getBoundingClientRect();
            /* Nur bei freier Groessenaenderung wird das Element angeheftet.
               Ein reiner Hoehenregler bleibt im Fluss seiner Leiste — die ist
               unten verankert, das Element waechst dadurch von selbst nach oben. */
            if (o.resize === 'both') pinToRect(el, r);
            el.style.maxHeight = 'none';
            const sx = e.clientX, sy = e.clientY, sw = r.width, sh = r.height;
            el.classList.add('is-sizing');

            const move = (ev) => {
                if (o.resize === 'both') {
                    el.style.width = clamp(sw + (ev.clientX - sx), o.minW,
                        window.innerWidth - r.left - MARGIN) + 'px';
                    el.style.height = clamp(sh + (ev.clientY - sy), o.minH,
                        window.innerHeight - r.top - MARGIN) + 'px';
                } else {
                    /* Anfasser an der Oberkante: nach oben ziehen vergroessert. */
                    el.style.height = clamp(sh - (ev.clientY - sy), o.minH,
                        r.bottom - MARGIN) + 'px';
                }
                o.onResize && o.onResize();
            };
            const up = () => {
                window.removeEventListener('mousemove', move);
                window.removeEventListener('mouseup', up);
                el.classList.remove('is-sizing');
                el.dataset.userSized = '1';   // Auto-Hoehe nicht mehr ueberschreiben
                store(el, o.key, o);
            };
            window.addEventListener('mousemove', move);
            window.addEventListener('mouseup', up);
        });
    }
}

/** Alles auf den Auslieferungszustand zuruecksetzen. */
const OVERRIDES = ['left', 'top', 'right', 'bottom', 'width', 'height',
                   'max-height', 'transform', 'margin'];

export function resetLayout() {
    layout = {};
    saveLayout();
    for (const { el } of registry) {
        delete el.dataset.userSized;
        /* Gezielt die gesetzten Eigenschaften entfernen — ein Regex ueber
           cssText wuerde auch border-left und Aehnliches treffen. */
        OVERRIDES.forEach((p) => el.style.removeProperty(p));
    }
}

/* Bildschirmgroesse geaendert: alles wieder in den sichtbaren Bereich holen. */
window.addEventListener('resize', () => {
    for (const { el, o } of registry) {
        if (o.resize === 'y') continue;      // bleibt an seiner Leiste
        const r = el.getBoundingClientRect();
        if (r.width === 0) continue;
        el.style.left = clamp(r.left, MARGIN, Math.max(MARGIN, window.innerWidth  - r.width  - MARGIN)) + 'px';
        el.style.top  = clamp(r.top,  MARGIN, Math.max(MARGIN, window.innerHeight - r.height - MARGIN)) + 'px';
        store(el, o.key, o);
    }
});
