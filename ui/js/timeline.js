/* ===========================================================================
   D-RPS — ui/js/timeline.js

   Das Datenband: vier Spuren am unteren Rand, zentrales Arbeitsmittel.

     Spur 1  Vorfaelle     Marker-Chips, klickbar
     Spur 2  Ereignisse    Schaden / Tod / Fahrzeugwechsel als feine Striche
     Spur 3  Telemetrie    Tempo- und Health-Kurve
     Spur 4  Zeitskala     Striche mit Zeitangabe, Dichte folgt dem Zoom

   PERFORMANCE — zwei getrennte Ebenen:
     bandStatic  Kurven, Marker, Skala. Wird NUR neu gezeichnet, wenn sich
                 Daten, Zoom oder Auswahl aendern.
     bandLive    Abspielkopf und Mauslinie. Wird pro Bild gezeichnet, ist aber
                 nur ein Strich plus Griff.
   Bei 60 Bildern/s spart das die vollstaendige Kurvenberechnung — der teure
   Teil laeuft nur noch bei echten Aenderungen. Zusaetzlich liegen die Kurven
   als Path2D vor, damit die Punktschleife nicht pro Zeichnung neu laeuft.
   =========================================================================== */

import { typeGlyph, t as tr } from './locale.js';

/* Systemfarben, dunkles Erscheinungsbild — deckungsgleich mit tokens.css */
const C = {
    well:   '#141416',
    lane:   'rgba(255,255,255,0.045)',
    l1:     'rgba(255,255,255,0.94)',
    l2:     'rgba(235,235,245,0.62)',
    l3:     'rgba(235,235,245,0.34)',
    accent: '#0A84FF',
    red:    '#FF453A',
    orange: '#FF9F0A',
    yellow: '#FFD60A',
    green:  '#30D158',
};

const T_INC = 30, T_EVT = 12, T_TEL = 40, T_SCALE = 22;

/* Nullpunkt der Gesundheit in GTA: 100 ist tot, nicht 0. */
const HP_DEAD = 100;
const PAD_X = 12;

function roundRect(g, x, y, w, h, r) {
    const rr = Math.min(r, w / 2, h / 2);
    g.beginPath();
    g.moveTo(x + rr, y);
    g.arcTo(x + w, y, x + w, y + h, rr);
    g.arcTo(x + w, y + h, x, y + h, rr);
    g.arcTo(x, y + h, x, y, rr);
    g.arcTo(x, y, x + w, y, rr);
    g.closePath();
}

export class Timeline {
    constructor(staticCv, liveCv, host, callbacks) {
        this.sc = staticCv;  this.sg = staticCv.getContext('2d');
        this.lc = liveCv;    this.lg = liveCv.getContext('2d', { alpha: true });
        this.host = host;
        this.cb = callbacks || {};

        this.duration  = 0;
        this.playT     = 0;
        this.incidents = [];
        this.events    = [];
        this.telemetry = [];
        this.gaps      = [];   /* Zeitraeume ohne Aufzeichnung (ausgeloggt) */
        this.activeId  = null;

        this.viewStart = 0;
        this.viewEnd   = 0;
        this.hover     = null;
        this.dragging  = false;

        this.dirtyStatic = true;
        this.dirtyLive   = true;
        this._paths = null;      /* zwischengespeicherte Kurven */

        this._bind();
        this._resize();

        const loop = () => {
            if (this.dirtyStatic) { this.dirtyStatic = false; this._drawStatic(); }
            if (this.dirtyLive)   { this.dirtyLive   = false; this._drawLive(); }
            requestAnimationFrame(loop);
        };
        requestAnimationFrame(loop);
    }

    /* ── Schnittstelle ────────────────────────────────────────────────── */

    setData({ duration, incidents, events, telemetry, gaps }) {
        this.duration  = duration || 0;
        this.incidents = (incidents || []).slice().sort((a, b) => a.relT - b.relT);
        this.events    = events || [];
        this.telemetry = telemetry || [];
        this.gaps      = gaps || [];
        this.viewStart = 0;
        this.viewEnd   = this.duration;
        this._invalidateAll();
    }

    setTelemetry(series, events, gaps) {
        this.telemetry = series || [];
        this.events    = events || [];
        this.gaps      = gaps || [];
        this._invalidateAll();
    }

    /* Laeuft 10x/s — darf NICHT den statischen Grund anfassen. */
    setTime(t) { this.playT = t; this.dirtyLive = true; }

    setActive(id) { this.activeId = id; this._invalidateAll(); }

    /** Nach dem Wiedereinblenden neu vermessen.
        Beim Schliessen liegt die Oberflaeche auf display:none — der Canvas hat
        dann die Groesse null. Ohne erneutes Vermessen bliebe er beim zweiten
        Oeffnen leer, weil sich die CSS-Hoehe nicht geaendert hat und der
        ResizeObserver deshalb nicht ausloest. */
    refresh() {
        this._resize();
        this._invalidateAll();
    }

    /** Nur den statischen Grund neu zeichnen — z. B. wenn sich ein Status aendert. */
    invalidateStatic() { this._paths = null; this.dirtyStatic = true; this._ensureHeight(); }

    /* Sicherheitsnetz: das Band darf unter keinen Umstaenden verschwinden.
       Wird bei jedem Neuzeichnen geprueft. */
    _ensureHeight() {
        const min = 44;
        const want = this.host.dataset.userSized
            ? Math.max(min, this.host.clientHeight)
            : this.neededHeight;
        if (this.host.clientHeight < min || (!this.host.dataset.userSized
            && this.host.clientHeight !== want)) {
            this.host.style.height = Math.max(min, want) + 'px';
        }
    }

    /* Spuren ohne Inhalt werden weggelassen. Auf einem ruhigen Server steht
       sonst die halbe Leiste leer und nimmt der Szene Bild weg. Die Hoehe des
       Behaelters folgt dem Ergebnis. */
    /* Telemetriespur und Zeitskala bleiben immer stehen — sie sind der
       Bezugsrahmen der Leiste. Nur Meldungen und Ereignisse entfallen, wenn
       nichts vorliegt; sonst schrumpft das Band auf eine Hoehe, bei der es
       nicht mehr als Zeitleiste erkennbar ist. */
    _layout() {
        const hasInc = this.incidents.length > 0;
        const hasEvt = this.events.length > 0;

        let y = 0;
        const L = { inc: -1, evt: -1, tel: -1, scale: -1,
                    hInc: T_INC, hEvt: T_EVT, hTel: T_TEL, hScale: T_SCALE };
        if (hasInc) { L.inc = y; y += T_INC; }
        if (hasEvt) { L.evt = y; y += T_EVT; }
        L.tel = y; y += T_TEL;
        L.scale = y; y += T_SCALE;
        L.total = y;

        /* Hat der Admin die Hoehe selbst eingestellt, muessen die Spuren ihr
           folgen. Mit festen Spurhoehen wurde die Zeitskala sonst unten
           abgeschnitten (zu kleines Band) oder es blieb toter Raum (zu grosses).
           Skala und Telemetrie tragen die Anpassung; die Markerspuren bleiben
           fein, weil sie nur Glyphen zeigen. */
        const avail = this.host.clientHeight;
        if (this.host.dataset.userSized && avail > 20 && Math.abs(avail - y) > 1) {
            const flexNow  = L.hTel + L.hScale;
            const flexWant = Math.max(24, flexNow + (avail - y));
            const k = flexWant / flexNow;
            L.hTel   = Math.max(12, Math.round(L.hTel * k));
            L.hScale = Math.max(12, flexWant - L.hTel);

            y = 0;
            if (hasInc) { L.inc = y; y += L.hInc; }
            if (hasEvt) { L.evt = y; y += L.hEvt; }
            L.tel = y; y += L.hTel;
            L.scale = y; y += L.hScale;
            L.total = y;
        }
        return L;
    }

    /** Gewuenschte Gesamthoehe in CSS-Pixeln — die Oberflaeche setzt sie. */
    get neededHeight() { return this._layout().total; }

    _invalidateAll() {
        this._paths = null; this.dirtyStatic = true; this.dirtyLive = true;
        // Hoehe an die tatsaechlich belegten Spuren anpassen
        // Hat der Admin die Hoehe selbst eingestellt, bleibt sie unangetastet.
        if (!this.host.dataset.userSized) {
            const h = this.neededHeight;
            if (this.host.clientHeight !== h) this.host.style.height = h + 'px';
        }
    }

    /* ── Geometrie ────────────────────────────────────────────────────── */

    get span()   { return Math.max(0.001, this.viewEnd - this.viewStart); }
    get innerW() { return Math.max(1, this.host.clientWidth - PAD_X * 2); }

    tToX(t) { return PAD_X + ((t - this.viewStart) / this.span) * this.innerW; }
    xToT(x) { return this.viewStart + ((x - PAD_X) / this.innerW) * this.span; }

    /* ── Ereignisse ───────────────────────────────────────────────────── */

    _bind() {
        this._ro = new ResizeObserver(() => this._resize());
        this._ro.observe(this.host);

        this.host.addEventListener('mousedown', (e) => {
            const inc = this._hitIncident(e.offsetX, e.offsetY);
            if (inc) { this.cb.onIncident && this.cb.onIncident(inc); return; }
            this.dragging = true;
            this._seekFrom(e.offsetX);
        });

        window.addEventListener('mousemove', (e) => {
            const r = this.host.getBoundingClientRect();
            const x = e.clientX - r.left, y = e.clientY - r.top;
            const inside = x >= 0 && x <= r.width && y >= 0 && y <= r.height;

            if (this.dragging) this._seekFrom(x);

            if (inside && this.duration > 0) {
                this.hover = { x, t: this.xToT(x), inc: this._hitIncident(x, y) };
                this.cb.onHover && this.cb.onHover(this.hover);
                this.dirtyLive = true;
            } else if (this.hover) {
                this.hover = null;
                this.cb.onHover && this.cb.onHover(null);
                this.dirtyLive = true;
            }
        });

        window.addEventListener('mouseup', () => { this.dragging = false; });

        /* Zoom um den Mauszeiger — noetig, sobald ein Archiv Stunden umfasst. */
        this.host.addEventListener('wheel', (e) => {
            e.preventDefault();
            if (!this.duration) return;
            const anchor = this.xToT(e.offsetX);
            const factor = e.deltaY > 0 ? 1.25 : 0.8;
            const span = Math.min(this.duration, Math.max(2, this.span * factor));
            let s = anchor - (anchor - this.viewStart) * (span / this.span);
            s = Math.max(0, Math.min(this.duration - span, s));
            this.viewStart = s; this.viewEnd = s + span;
            this._invalidateAll();
        }, { passive: false });
    }

    _seekFrom(x) {
        const t = Math.max(0, Math.min(this.duration, this.xToT(x)));
        this.cb.onSeek && this.cb.onSeek(t);
    }

    _hitIncident(x, y) {
        const L = this._layout();
        if (L.inc < 0 || y > L.inc + L.hInc + 2) return null;
        for (const inc of this.incidents) {
            const half = (inc._hitW || 20) / 2;
            if (Math.abs(this.tToX(inc.relT) - x) <= half) return inc;
        }
        return null;
    }

    _resize() {
        const dpr = Math.min(2, window.devicePixelRatio || 1);   /* 2 reicht optisch */
        const w = this.host.clientWidth, h = this.host.clientHeight;
        // Waehrend die Oberflaeche ausgeblendet ist, meldet der Behaelter 0.
        // Dann NICHT verkleinern — sonst bleibt der Canvas beim naechsten
        // Oeffnen leer.
        if (w < 2 || h < 2) return;
        for (const [cv, g] of [[this.sc, this.sg], [this.lc, this.lg]]) {
            cv.width  = Math.max(1, Math.round(w * dpr));
            cv.height = Math.max(1, Math.round(h * dpr));
            g.setTransform(dpr, 0, 0, dpr, 0, 0);
        }
        this._invalidateAll();
    }

    /* ── Kurven einmalig vorberechnen ─────────────────────────────────── */

    /* Tempo als Flaechenkurve, Health als farbiges Band.

       Health war urspruenglich eine Linie — das sah schlecht aus: sie lag die
       meiste Zeit flach am oberen Rand und stuerzte beim Tod senkrecht ab.
       Ein Band traegt denselben Inhalt ruhiger: die Farbe zeigt den Zustand,
       eine Luecke zeigt den Tod. Keine Linie, die abbrechen koennte. */
    _buildPaths(yTel, hTel) {
        const tel = this.telemetry;
        const paths = { speedFill: null, speedLine: null, hpRuns: [] };
        if (!tel.length) return paths;

        const STRIP = 5;                       /* Hoehe des Health-Bands */
        const bot = yTel + hTel - STRIP - 5;   /* Grundlinie der Tempokurve */
        const top = yTel + 5;
        const span = Math.max(4, bot - top);

        let maxSpeed = 1, maxHealth = 1;
        for (const p of tel) {
            if (p.speed > maxSpeed) maxSpeed = p.speed;
            if (p.health > maxHealth) maxHealth = p.health;
        }

        /* Tempo */
        const line = new Path2D(), fill = new Path2D();
        let started = false, lastX = 0;
        for (const p of tel) {
            if (p.t < this.viewStart - 1 || p.t > this.viewEnd + 1) continue;
            const x = this.tToX(p.t);
            const y = bot - (p.speed / maxSpeed) * span;
            if (!started) { line.moveTo(x, y); fill.moveTo(x, bot); fill.lineTo(x, y); started = true; }
            else { line.lineTo(x, y); fill.lineTo(x, y); }
            lastX = x;
        }
        if (started) {
            fill.lineTo(lastX, bot); fill.closePath();
            paths.speedLine = line; paths.speedFill = fill;
        }

        /* Health-Band: zusammenhaengende Abschnitte, in denen der Spieler lebt.
           Jeder Abschnitt wird in Teilstuecke gleicher Farbstufe zerlegt, damit
           nur wenige Rechtecke noetig sind. */
        const stripY = yTel + hTel - STRIP - 2;
        let run = null;
        const flush = () => { if (run && run.pieces.length) paths.hpRuns.push(run); run = null; };

        for (let i = 0; i < tel.length; i++) {
            const p = tel[i];
            if (p.t < this.viewStart - 1 || p.t > this.viewEnd + 1) continue;
            /* GTA zaehlt Gesundheit von 100 (tot) bis 200 (voll) — nicht von 0.
               Ohne diesen Nullpunkt ergibt selbst ein Sterbender noch gut 0,5
               und wurde gelb oder gruen gezeichnet; Rot war unerreichbar. */
            const alive = (p.alive !== undefined) ? p.alive : (p.health > HP_DEAD);
            if (!alive) { flush(); continue; }

            const hpTop = Math.max(HP_DEAD + 1, maxHealth);
            const frac  = Math.max(0, Math.min(1, (p.health - HP_DEAD) / (hpTop - HP_DEAD)));
            const tone = frac > 0.66 ? C.green : (frac > 0.33 ? C.yellow : C.red);
            const x = this.tToX(p.t);
            const next = tel[i + 1];
            const xEnd = next ? this.tToX(next.t) : x + 2;

            if (!run) run = { y: stripY, h: STRIP, pieces: [] };
            const last = run.pieces[run.pieces.length - 1];
            if (last && last.tone === tone && Math.abs(last.x + last.w - x) < 1.5) {
                last.w = xEnd - last.x;                     /* Teilstueck verlaengern */
            } else {
                run.pieces.push({ x, w: Math.max(1, xEnd - x), tone });
            }
        }
        flush();

        return paths;
    }

    /* ── Statische Ebene ──────────────────────────────────────────────── */

    _drawStatic() {
        this._ensureHeight();
        const g = this.sg;
        const w = this.host.clientWidth, h = this.host.clientHeight;

        g.clearRect(0, 0, w, h);
        g.fillStyle = C.well;
        g.fillRect(0, 0, w, h);

        if (!this.duration) {
            g.fillStyle = C.l3;
            g.font = '12px -apple-system, "Segoe UI", system-ui, sans-serif';
            g.textAlign = 'center';
            g.fillText(tr('band.empty'), w / 2, h / 2 + 4);
            g.textAlign = 'left';
            return;
        }

        const L = this._layout();

        if (L.tel >= 0) {
            g.fillStyle = C.lane;
            roundRect(g, PAD_X - 4, L.tel + 2, w - (PAD_X - 4) * 2, L.hTel - 4, 6);
            g.fill();

            if (!this._paths) this._paths = this._buildPaths(L.tel, L.hTel);
            const P = this._paths;

            if (P.speedFill) {
                g.fillStyle = 'rgba(255,255,255,0.09)';
                g.fill(P.speedFill);
                g.strokeStyle = 'rgba(255,255,255,0.45)';
                g.lineWidth = 1.2; g.lineJoin = 'round';
                g.stroke(P.speedLine);
            }

            /* Health-Band: durchgehende Abschnitte mit abgerundeten Enden. */
            for (const run of P.hpRuns) {
                const first = run.pieces[0];
                const last  = run.pieces[run.pieces.length - 1];
                const x0 = first.x, x1 = last.x + last.w;

                g.save();
                roundRect(g, x0, run.y, Math.max(2, x1 - x0), run.h, run.h / 2);
                g.clip();
                for (const pc of run.pieces) {
                    g.fillStyle = pc.tone;
                    g.fillRect(pc.x, run.y, pc.w + 0.6, run.h);
                }
                g.restore();
            }

            g.fillStyle = C.l3;
            g.font = '10px -apple-system, "Segoe UI", system-ui, sans-serif';
            g.fillText(tr('band.speed'), PAD_X, L.tel + 12);
        }

        if (L.evt >= 0) this._drawEvents(g, L.evt, L.hEvt);
        this._drawScale(g, w, L.scale, L.hScale);
        this._drawGaps(g, L);
        if (L.inc >= 0) this._drawIncidents(g, L.inc, L.hInc);
    }

    /* Zeitraeume, in denen der verfolgte Spieler nicht auf dem Server war.

       Ohne diese Kennzeichnung ist im Band nicht unterscheidbar, ob in einem
       Abschnitt nichts passiert ist oder ob niemand da war — und der Klon in
       der Szene verschwindet scheinbar grundlos. Die Schraffur laeuft ueber
       die volle Bandhoehe, damit sie sich nicht mit einer Datenspur verwechseln
       laesst, und traegt an ihren Kanten die beiden Zeitpunkte. */
    _drawGaps(g, L) {
        if (!this.gaps || !this.gaps.length) return;

        for (const gap of this.gaps) {
            if (gap.to < this.viewStart || gap.from > this.viewEnd) continue;
            const x0 = Math.max(PAD_X, this.tToX(gap.from));
            const x1 = Math.min(this.host.clientWidth - PAD_X, this.tToX(gap.to));
            const wGap = x1 - x0;
            if (wGap < 1) continue;

            g.save();
            g.beginPath();
            g.rect(x0, 0, wGap, L.total);
            g.clip();

            /* Gedaempfter Grund, darueber diagonale Striche. Die Schraffur ist
               das einzige Muster im Band, das nicht fuer Daten steht. */
            g.fillStyle = 'rgba(10,12,16,0.55)';
            g.fillRect(x0, 0, wGap, L.total);

            g.strokeStyle = 'rgba(235,235,245,0.16)';
            g.lineWidth = 1;
            g.beginPath();
            for (let x = x0 - L.total; x < x1 + L.total; x += 7) {
                g.moveTo(x, L.total);
                g.lineTo(x + L.total, 0);
            }
            g.stroke();
            g.restore();

            /* Senkrechte an beiden Kanten: hier ging er raus, hier kam er wieder. */
            g.strokeStyle = 'rgba(255,159,10,0.85)';
            g.lineWidth = 1.5;
            g.beginPath();
            g.moveTo(x0 + 0.5, 0); g.lineTo(x0 + 0.5, L.total);
            g.moveTo(x1 - 0.5, 0); g.lineTo(x1 - 0.5, L.total);
            g.stroke();

            if (wGap > 74) {
                g.fillStyle = 'rgba(255,159,10,0.95)';
                g.font = '10px -apple-system, "Segoe UI", system-ui, sans-serif';
                g.textAlign = 'center';
                g.fillText(tr('band.absent'), (x0 + x1) / 2, L.total / 2 + 3);
                g.textAlign = 'left';
            }
        }
    }

    _drawEvents(g, y, hh) {
        for (const ev of this.events) {
            if (ev.t < this.viewStart || ev.t > this.viewEnd) continue;
            const x = this.tToX(ev.t);
            const isDeath = ev.kind === 'death';
            g.fillStyle = isDeath ? C.red : (ev.kind === 'vehicle' ? C.l3 : C.l2);
            const bh = isDeath ? hh - 4 : hh - 7;
            roundRect(g, x - 1, y + (hh - bh) / 2, 2, bh, 1);
            g.fill();
        }
    }

    _drawScale(g, w, y, hh) {
        const rough = (this.span / this.innerW) * 92;
        const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200];
        let step = steps[steps.length - 1];
        for (const s of steps) if (s >= rough) { step = s; break; }

        g.font = '10px "SF Mono", ui-monospace, Consolas, monospace';
        g.textAlign = 'center';

        const sub = step / 5;
        if (sub >= 0.5) {
            g.fillStyle = C.l3; g.globalAlpha = 0.45;
            for (let t = Math.ceil(this.viewStart / sub) * sub; t <= this.viewEnd; t += sub) {
                g.fillRect(Math.round(this.tToX(t)), y + 4, 1, 3);
            }
            g.globalAlpha = 1;
        }
        for (let t = Math.ceil(this.viewStart / step) * step; t <= this.viewEnd; t += step) {
            const x = Math.round(this.tToX(t));
            g.fillStyle = C.l3; g.fillRect(x, y + 4, 1, 6);
            g.fillStyle = C.l2; g.fillText(fmtShort(t), x, y + hh - 4);
        }
        g.textAlign = 'left';
    }

    _drawIncidents(g, y, hh) {
        const perPx = this.span / this.innerW;
        g.font = '600 10px -apple-system, "Segoe UI", system-ui, sans-serif';
        g.textAlign = 'center';
        g.textBaseline = 'middle';

        const cy = y + hh / 2;
        let lastRight = -999;

        for (const inc of this.incidents) {
            if (inc.relT < this.viewStart - perPx || inc.relT > this.viewEnd + perPx) continue;
            const x = this.tToX(inc.relT);
            const isActive = inc.key === this.activeId;

            /* Meldungen tragen ein schlichtes T. Erledigte treten zurueck,
               automatische Hinweise behalten ihr Kuerzel. */
            const label = inc.auto ? typeGlyph(inc.type) : 'T';
            const tone = inc.auto
                ? ((inc.confidence || 0) >= 0.8 ? C.red : C.orange)
                : (inc.status === 'closed' ? C.l3
                   : (inc.status === 'progress' ? C.accent : C.orange));
            const wChip = Math.max(inc.auto ? 26 : 22, g.measureText(label).width + 14);

            if ((x - wChip / 2) > lastRight + 4) {
                g.fillStyle = isActive ? C.accent : tone;
                roundRect(g, x - wChip / 2, cy - 9, wChip, 18, 5);
                g.fill();
                g.fillStyle = '#fff';
                g.fillText(label, x, cy + 0.5);
                lastRight = x + wChip / 2;
                inc._hitW = wChip;
            } else {
                g.fillStyle = isActive ? C.accent : tone;
                roundRect(g, x - 2, cy - 5, 4, 10, 2);
                g.fill();
                inc._hitW = 8;
            }
        }
        g.textBaseline = 'alphabetic';
        g.textAlign = 'left';
    }

    /* ── Bewegte Ebene: nur Abspielkopf und Mauslinie ─────────────────── */

    _drawLive() {
        const g = this.lg;
        const w = this.host.clientWidth, h = this.host.clientHeight;
        g.clearRect(0, 0, w, h);
        if (!this.duration) return;

        if (this.hover && !this.dragging) {
            g.fillStyle = 'rgba(255,255,255,0.20)';
            g.fillRect(Math.round(this.hover.x), 0, 1, h);
        }

        const x = this.tToX(this.playT);
        if (x < -6 || x > w + 6) return;
        g.fillStyle = 'rgba(0,0,0,0.35)';
        g.fillRect(Math.round(x), 0, 2, h);
        g.fillStyle = '#fff';
        g.fillRect(Math.round(x), 0, 1, h);
        roundRect(g, x - 5, 0, 10, 12, 3);
        g.fill();
    }
}

/* ── Formatierung ────────────────────────────────────────────────────────── */

function fmtShort(sec) {
    sec = Math.max(0, Math.floor(sec));
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
    return `${m}:${String(s).padStart(2, '0')}`;
}

/** HH:MM:SS.mmm — der Ankerpunkt der Oberflaeche. */
export function fmtTimecode(sec) {
    sec = Math.max(0, sec || 0);
    const h  = Math.floor(sec / 3600);
    const m  = Math.floor((sec % 3600) / 60);
    const s  = Math.floor(sec % 60);
    const ms = Math.floor((sec - Math.floor(sec)) * 1000);
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:` +
           `${String(s).padStart(2, '0')}.${String(ms).padStart(3, '0')}`;
}
