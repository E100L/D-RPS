# D-RPS — Dollar Replay System
## Technisches Konzept & Produktdefinition

**Version:** 0.1 (Entwurf)
**Datum:** 2026-07-16
**Autor:** Dollar Development
**Status:** Konzeptphase — noch kein Code

---

## Inhalt

1. [Zielbild in einem Absatz](#1-zielbild)
2. [Marktlage: was existiert wirklich](#2-marktlage)
3. [Die harten Wände — verifizierte Engine-Grenzen](#3-harte-waende)
4. [Architektur-Überblick](#4-architektur)
5. [Datenmodell & Binärformat](#5-datenmodell)
6. [Recorder (Server)](#6-recorder)
7. [Reporter (Client)](#7-reporter)
8. [Ringpuffer & Speicher](#8-ringpuffer)
9. [Transport & Streaming](#9-transport)
10. [Playback-Engine (3D)](#10-playback)
11. [Szenen-Rekonstruktion](#11-szene)
12. [Lokomotion & Animation](#12-lokomotion)
13. [Detection-Layer](#13-detection)
14. [Admin-UI: Ingame & Web](#14-ui)
15. [Performance-Budget](#15-performance)
16. [Sicherheit & Anti-Tamper](#16-sicherheit)
17. [Integration: Config, Bridge, Exports](#17-integration)
18. [DSGVO & Rechtliches](#18-dsgvo)
19. [Tebex, Escrow, Pricing](#19-tebex)
20. [Roadmap](#20-roadmap)
21. [Offene Entscheidungen & Risiken](#21-offen)
22. [Verifikationsliste vor Code-Start](#22-verifikation)

---

<a name="1-zielbild"></a>
## 1. Zielbild in einem Absatz

D-RPS zeichnet den **Zustand** eines FiveM-Servers kontinuierlich in einen RAM-Ringpuffer auf und rekonstruiert ihn auf Abruf als **frei begehbare 3D-Szene** — in einer isolierten Routing-Bucket-Instanz, mit Freikamera, Timeline, Scrubbing, Zeitlupe und Sprungmarken auf Ereignisse.

**Zweck: Regelbrüche nachvollziehbar machen.** RDM, VDM, Combat-Logging, NLR-Verstöße, Fail-RP — die Fälle, mit denen RP-Admins tatsächlich ihre Zeit verbringen. Ein Detection-Layer erzeugt aus denselben Daten Verdachtsfälle als **Hinweise zur menschlichen Prüfung**, nie als Automatik-Bans. Cheat-Erkennung ist ein Nebenprodukt, kein Kernversprechen.

Kein Video, kein CDN, keine laufenden Fremdkosten, Bandbreite im Kilobyte- statt Megabyte-Bereich.

**Die Produktthese in einem Satz:** *D-RPS erkennt, was erkennbar ist, und macht den Rest überprüfbar* — die Detection füllt die Warteschlange, das Replay leert sie.

**Das Alleinstellungsmerkmal:** Es gibt derzeit kein FiveM-Produkt, das strukturierten Spielzustand als Admin-Beweismittel aufzeichnet. Alle Wettbewerber sind entweder Live-Spectate-Kameras oder Videoaufnahme — und keiner davon wertet aus.

---

<a name="2-marktlage"></a>
## 2. Marktlage: was existiert wirklich

### 2.1 thug-replay-system — der einzige echte Wettbewerber

Verifiziert aus der Hersteller-Doku (`thug.gitbook.io/documentation`):

| Preset | Auflösung | FPS | Bitrate |
|---|---|---|---|
| Low | 1280×720 | 30 | 3 Mbps |
| Normal | 1280×720 | 35 | 5 Mbps |
| High | 1280×720 | 50 | 8 Mbps |

Auflösung + FPS + **Bitrate** = Videoencoding. Bestätigt: benötigt **zwingend einen FiveManage-Video-API-Key**, max. Aufnahmedauer 15 Sekunden, kein Scrubbing, keine Freikamera. Preis: 17,99 € Escrow / 49,99 € Open Source.

Der Aufnahmeweg ist NUI-basiert (MediaRecorder/WebCodecs im eingebetteten Chromium, VP9 → WebM, Chunks an den Server gestreamt) — die Technik, die `itschip/screencapture` öffentlich implementiert.

**Vier strukturelle Schwächen — nicht durch Iteration behebbar:**

1. **Das Retroaktivitäts-Problem.** Ein Killcam muss zeigen, was *vor* dem Tod passierte. Mit MediaRecorder heißt das: **jeder Spieler nimmt permanent seinen eigenen Bildschirm auf**, dauerhaft, um einen Rolling Buffer zu halten. Die „15s max mit Auto-Reset"-Config *ist* dieser Puffer.

2. **„Extremely low resmon" ist irreführend.** resmon misst Lua-Tickzeit. Es misst **nicht** den CEF/Chromium-Prozess, der VP9 encodiert, und nicht die Upload-Bandbreite. Die Aussage kann wörtlich stimmen, während das Script echte FPS und echten Uplink kostet. **Das ist unser schärfster Hebel im Marketing.**

3. **Versteckte Dauerkosten.** 15 s @ 3 Mbps ≈ 5,6 MB pro Clip; @ 8 Mbps ≈ 15 MB. Zwei POVs pro Kill verdoppeln das. Ein PvP-Server mit ~2.000 Kills/Tag auf „Normal" ≈ **19 GB/Tag**. FiveManage Free = 10 GB Storage / 30 GB Traffic; Pro (15 $/Monat) = 120 GB / 1 TB, Overage 0,10 $/GB. **Der 17,99-€-Aufkleber verdeckt eine Pflicht-Abo-Kette.**

4. **Fragilität.** Das zugrundeliegende `screencapture`-README warnt selbst: VP9-Encoding hängt an der WebCodecs-API in FiveMs gebündeltem Chromium; schlägt es still fehl, enthält die Datei nur den Container-Header. Nicht breit über FiveM-Builds und CEF-Versionen getestet.

### 2.2 Der Rest der Kategorie

Verifiziert: **fast alle „Killcams" sind Live-Spectate-Kameras, keine Replays.** Sie hängen im Todesmoment eine Kamera an den Killer und blenden Infos ein. Keine Aufzeichnung, kein Puffer, kein Rücklauf. Das gilt für GFX Deathcam V1/V2, Zen Kill Cam, Authentic, BBS Killcam.

Preisband der Kategorie (verifiziert): **4–50 €**, Open-Source-Stufe typisch 2,0–3,0× der Escrow-Stufe.

| Produkt | Escrow | Open Source |
|---|---|---|
| Zen Kill Cam | 4,00 € | 8,00 € |
| gfx-deathcam V2 | 10 € | 30 € |
| gfx-deathcam V1 | 15 € | 30 € |
| **thug-replay-system** | **17,99 €** | **49,99 €** |
| BBS Killcam | 19,99 € | — |
| Authentic KillCam | 14,00 € | — |

Anticheat ist ein anderes Band und meist Abo: FiniAC 34,99–49,99 €/Mon, Raven 20 $/Mon, Gamzky 11,99 € Escrow / 44,99 € Source (einmalig).

**Open Source, das existiert:** `lucid-killcam` (gratis), Patrik Papšos Vehicle-Replay-Artikel (Position/Heading pro Tick + Playback — genau unser Ansatz, aber nur Fahrzeuge), `yvr_recorder`, `ClipSaverV`.

**Die Lücke:** Kein FiveM-Resource hält einen Ringpuffer aus Kampfzustand (Positionen + Aim + Damage-Events) für Admin-Review. Existierende Killcams sind spielerseitige Kino-Effekte; Death-Logger sind einzeilige Discord-Webhooks. Electron AC / Reaper / Raven bewerben „Session Replay", aber kein Anbieter dokumentiert ein Format — vermutlich ebenfalls Video.

### 2.3 Unsere Positionierung

| | thug (Video) | **D-RPS (State)** |
|---|---|---|
| Bandbreite/Spieler | ~375–1000 KB/s (Upload) | **~0,35 KB/s** |
| Laufende Kosten | FiveManage-Abo zwingend | **keine** |
| Freikamera | nein | **ja** |
| Scrubbing / Zeitlupe | nein | **ja** |
| Rückwirkende Dauer | 15 s | **15–60 min konfigurierbar** |
| Client-CPU | VP9-Encoding permanent | **< 0,1 ms Lua-Tick** |
| Sieht 100 % echt aus | **ja** | nein — Rekonstruktion |
| Detection-Auswertung | nein | **ja** |
| Beweist Silent Aim | nein | **teilweise** (siehe §13) |

Der einzige Punkt, an dem Video gewinnt, ist visuelle Authentizität. Für alles andere — Dauer, Kosten, Kamerafreiheit, Auswertbarkeit — ist State um Größenordnungen besser. **Faktor ~100–240× günstiger als die *niedrigste* Videoqualität.**

---

<a name="3-harte-waende"></a>
## 3. Die harten Wände — verifizierte Engine-Grenzen

Diese Punkte sind aus Cfx-Quellcode bzw. der offiziellen Native-DB verifiziert. Sie sind nicht verhandelbar und bestimmen die Architektur.

### 3.1 Kein Packet-Replay. Punkt.

Es gibt **keine API, den Sync-Stream aufzuzeichnen oder zurückzuspielen.** Dreifach bestätigt:

- Die einzigen ähnlichen Natives (`EXPERIMENTAL_SAVE_CLONE_CREATE`, `_SYNC`, `LOAD_*`) sind **client-only und tragen in ihrer eigenen Doku wörtlich „This native is not implemented."** Serverseitig existieren sie gar nicht.
- Kein Injection-Punkt: Serverseitig gibt es keinen Pfad, der einen Sync-Node schreibt.
- Die Architektur schließt es aus: Sync-Trees werden vom **besitzenden Client** verfasst, der Server deserialisiert und leitet weiter. Deshalb ist `SET_ENTITY_COORDS` serverseitig ein RPC an den Owner statt ein echter Setter — und `SetEntityHealth` existiert serverseitig überhaupt nicht.

→ **Rekonstruktion auf Entity-Ebene ist der einzige Weg.** Genau das, was Minecraft *nicht* muss (dort ist `.mcpr` ein roher Packet-Dump).

### 3.2 Server-Tick = 50 ms. 20 Hz ist die Decke.

Aus `GameServer.cpp`:

| Thread | Intervall |
|---|---|
| **svMain (Scripts)** | 1000/20 = **50 ms / 20 Hz** |
| svNetwork | 10 ms |
| svSync | 8,3 ms |

`ServerGameState::Tick` drosselt sich zusätzlich → **40 Hz Entity-Sync** by default.

**Konsequenzen:**
- `Wait(0)` serverseitig ≈ 50 ms, nicht ein Frame.
- `Wait(50)` = 1 Tick, `Wait(100)` = 2 Ticks — beide genau.
- **Unter 50 ms ist serverseitig nicht erreichbar.** Kein Trick.
- `GetGameTimer()` serverseitig hat 50-ms-Granularität. Für Sub-Tick-Zeitstempel `os.clock()` nutzen.
- svMain ist **single-threaded und wird von allen Resources geteilt**. Tick > 150 ms ⇒ `server thread hitch warning`.

→ **Unser Format ist auf 50-ms-Frames ausgelegt.** 20 Hz Server-Sampling ist die Obergrenze und gleichzeitig völlig ausreichend, weil wir interpolieren.

### 3.3 Serverseitig gibt es keine Kleidung

Grep über die Server-Natives nach `GetPedDrawableVariation|GetPedTextureVariation|GetPedPropIndex` → **null Treffer.** Nur Setter existieren, und alle sind RPC.

→ **Appearance muss vom Client gemeldet werden** (oder du bist die Instanz, die sie gesetzt hat, und speicherst sie selbst).

### 3.4 Serverseitige Kamera: nur Yaw, und grob

`GET_PLAYER_CAMERA_ROTATION` (0x433C765D, OneSync-only) existiert — **aber**:
- Geparst als `ReadSignedFloat(10, 6.2831855f)` → **10 Bit über 2π ≈ 0,35° Auflösung**
- **`y` ist hart auf 0.0f gesetzt ⇒ Pitch wird verworfen**
- Es ist client-verfasste Sync-Data, keine Messung

Zusätzlich: **serverseitig ist kein Shapetest/Raycast registriert** ⇒ Line-of-Sight-Prüfung auf dem Server ist nicht bloß fehlend, sondern **unmöglich**.

→ Für brauchbare Aim-Daten brauchen wir den Client-Reporter (§7). Und für LOS-Prüfung den Trick aus §13.4.

### 3.5 Es gibt kein „gib mir die laufende Animation"

Bestätigt durch vollständigen Grep beider Native-DBs. Die kompletten Anim-Reader:

```
IS_ENTITY_PLAYING_ANIM(entity, dict, name, flag)     -- braucht dict+name als INPUT
GET_ENTITY_ANIM_CURRENT_TIME(entity, dict, name)     -- dito
GET_ENTITY_ANIM_TOTAL_TIME(entity, dict, name)       -- dito
GET_ANIM_DURATION(dict, name)                        -- dito
```

Kein Enumerations-Native. `GetPedTaskCurrent` existiert nicht.

**Und der tiefere Killer:** Es gibt **keinen `SET_ENTITY_BONE_*`-Setter** in irgendeiner DB. Die Getter (`_GET_ENTITY_BONE_ROTATION`, `GET_WORLD_POSITION_OF_ENTITY_BONE`) existieren — du kannst eine Skelett-Pose *lesen*, aber nicht *schreiben*. **Direktes Pose-Replay ist unmöglich.** (`GET_PED_BONE_MATRIX` ist RDR3-only — nicht einplanen.)

→ Lösung in §12: Anims an der Quelle instrumentieren + Lokomotion durch die Engine-KI rekonstruieren.

### 3.6 Kein LuaJIT, kein FFI

FiveMs Lua ist **CfxLua** — ein Fork von LuaGLM (Lua 5.4.4). **Kein JIT.** Kein LuaJIT ⇒ **kein FFI**. Interpretertempo einplanen.

Geladene Libs: `_G`, `table`, `string`, `math`, `coroutine`, `utf8`, `debug`, serverseitig zusätzlich `io`/`os` (sandboxed), `msgpack` (C), `json` (rapidjson, C). **`package` fehlt — kein `require`.**

GC: Standard Lua 5.4 **inkrementell**. FiveM aktiviert **keinen** Generational Mode und tunt GC-Parameter nicht. **Du besitzt deine Allokationsrate selbst.**

### 3.7 resmon-Schwellen (aus `ResourceMonitor.cpp`)

- Warnung bei **`avgTickTime > 6 ms`**, hartkodiert
- Mittelung über **64 Ticks** — ein einzelner 300-ms-Ausreißer löst *nicht* aus, dauerhafte 6 ms schon
- Farbrampe: **grün < 1,0 ms, rot ab 8,0 ms**
- Gemessen als **Self-Time** der Resource

→ **Unser Ziel: < 1,0 ms avg clientseitig. Das ist die einzige im Code verankerte Definition von „akzeptabel".**

### 3.8 Client-Fokuszone = 424 Units

OneSync lädt clientseitig nur Entities innerhalb **424 Units**. Der Server hat vollständige Daten, Clients einen gefilterten Ausschnitt.

→ **Globale Abdeckung erfordert serverseitiges Recording.** Clientseitiges Sampling fremder Entities verpasst still alles jenseits 424 Units.

### 3.9 `weaponDamageEvent` ist eine Behauptung, kein Messwert

Offizielle Doku: *„Triggered when a client wants to apply damage to a remotely-owned entity."* Der Client verfasst die Payload **und** wählt die Empfängerliste. Der Server berechnet keinen Schaden. Validierung: Paketgröße ≤ 1552 B, Target-Dedup, Routing-Bucket-Filter. **`weaponDamage`, `willKill`, `hitComponent`, `damageTime` sind allesamt angreifer-geliefert und trivial fälschbar.**

Vollständige Payload (aus `ServerGameState.cpp:4927`), die für uns relevanten Felder:

```
damageType, weaponType, overrideDefaultDamage, hitEntityWeapon,
silenced, damageFlags, weaponDamage, isNetTargetPos,
localPosX/Y/Z, damageTime, willKill, parentGlobalId,
hitGlobalId, hitGlobalIds[], hitComponent,
hasImpactDir, impactDirX/Y/Z
```

Cancelbar: ja — `CancelEvent()` verhindert das Weiterleiten an die Zielclients (macht aber die lokale Prediction des Schützen nicht rückgängig).

⚠️ **Bekannter Bug:** [citizenfx/fivem#2395](https://github.com/citizenfx/fivem/issues/2395) — häufiges Canceln lässt Opfer *„nur für Client-1 tot erscheinen"*, Leichen nehmen weiter Schaden, „tote" Spieler schießen weiter. **Offen, unassigned.** ⇒ **D-RPS cancelt niemals `weaponDamageEvent`. Wir sind ein Recorder, kein Blocker.** Das ist auch ein Verkaufsargument: Wir kollidieren nicht mit dem Anticheat des Kunden.

### 3.10 Escrow schützt kein NUI

Verifiziert aus der Escrow-Doku: **nur Lua, YFT, YDD, YDR können escrowed werden. NUI wird nicht unterstützt.** Unsere UI liegt in jedem Fall offen.

→ **Der Wert darf nicht in der UI liegen.** Er liegt im Format, im Recorder und im Detection-Layer.

---

<a name="4-architektur"></a>
## 4. Architektur-Überblick

Fünf Komponenten, klare Trennlinien:

```
┌─────────────────────────────────────────────────────────────────┐
│ CLIENT (jeder Spieler)                                          │
│                                                                 │
│  ┌──────────────────────────────────────────────┐               │
│  │ REPORTER            client/reporter.lua      │               │
│  │  • eigener Ped: Anim-State, Flags, Kamera    │  20 Hz        │
│  │  • Appearance-Snapshot (einmalig + on change)│               │
│  │  • gepackt, gebatcht, 1×/s hochgeladen       │  ~0.1 KB/s    │
│  │  • FIDELITY-LAYER — spoofbar, nicht Beweis   │               │
│  └──────────────────────────────────────────────┘               │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│ SERVER                                                          │
│                                                                 │
│  ┌──────────────────────────────────────────────┐               │
│  │ RECORDER            server/recorder.lua      │               │
│  │  • Positionen, Health, Fahrzeug, Rotation    │  20 Hz        │
│  │  • autoritativ, aus dem Sync-Tree            │               │
│  │  • EVIDENCE-LAYER — belastbar                │               │
│  └──────────────────┬───────────────────────────┘               │
│                     │                                           │
│  ┌──────────────────▼───────────────────────────┐               │
│  │ EVENT-COLLECTOR     server/events.lua        │               │
│  │  • weaponDamageEvent, explosionEvent,        │               │
│  │    startProjectileEvent, giveWeaponEvent,    │  ereignis-    │
│  │    entityCreated, clearPedTasksEvent         │  getrieben    │
│  │  • als CLAIMS gespeichert, nie als Wahrheit  │               │
│  └──────────────────┬───────────────────────────┘               │
│                     │                                           │
│  ┌──────────────────▼───────────────────────────┐               │
│  │ RING BUFFER         server/ringbuffer.lua    │               │
│  │  • gepackte Binär-Chunks, 1 s pro Chunk      │  ~40 MB       │
│  │  • pro Spieler, RAM-only, FIFO               │  / 30 min     │
│  └──────────────────┬───────────────────────────┘               │
│                     │                                           │
│  ┌──────────────────▼───────────────────────────┐               │
│  │ DETECTION           server/detection.lua     │               │
│  │  • Heuristiken über Ring + Events            │               │
│  │  • erzeugt FLAGS, niemals Bans               │               │
│  └──────────────────┬───────────────────────────┘               │
│                     │                                           │
│  ┌──────────────────▼───────────────────────────┐               │
│  │ SESSION-SERVER      server/session.lua       │               │
│  │  • Segment-Streaming an Admin-Clients        │               │
│  │  • räumliche Filterung, Prefetch             │               │
│  │  • SetHttpHandler für Web-Portal             │               │
│  └──────────────────┬───────────────────────────┘               │
└─────────────────────┼───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│ ADMIN-CLIENT                                                    │
│                                                                 │
│  ┌──────────────────────────────────────────────┐               │
│  │ PLAYBACK-ENGINE     client/playback.lua      │               │
│  │  • Routing Bucket (isoliert, Population off) │               │
│  │  • lokale Klon-Peds (isNetwork = false)      │               │
│  │  • Interpolation, Lokomotion, Freikamera     │               │
│  │  • Mode A: Playback (KI-getrieben, natürlich)│               │
│  │  • Mode B: Scrub (pose-getrieben, exakt)     │               │
│  └──────────────────────────────────────────────┘               │
│  ┌──────────────────────────────────────────────┐               │
│  │ NUI                 ui/ (React + Vite)       │               │
│  │  • Timeline, Scrubber, Event-Marker          │               │
│  │  • Spielerliste, Filter, Detection-Flags     │               │
│  └──────────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────────┘
```

### 4.1 Die zentrale Designentscheidung: zwei Vertrauensschichten

Das wichtigste Prinzip des ganzen Systems:

| | **Evidence-Layer** | **Fidelity-Layer** |
|---|---|---|
| Quelle | Server (Sync-Tree) | Client-Reporter |
| Inhalt | Position, Health, Fahrzeug, Rotation | Anims, Kleidung, Kamera, Flags |
| Rate | 20 Hz | 20 Hz |
| Fälschbar | nein (Sync-Tree ist ebenfalls client-verfasst, aber durch Movement-Plausibilität gedeckelt) | **ja** |
| Verwendung | Beweis, Detection | Optik, **Widerspruchsprüfung** |

Beide werden getrennt gespeichert und in der UI **getrennt gekennzeichnet**. Ein Admin muss auf einen Blick sehen, ob er auf Server-Daten oder Client-Behauptungen schaut. Das ist kein Detail — es ist der Unterschied zwischen einem Beweismittel und einem hübschen Video.

### 4.2 Warum der Fidelity-Layer trotzdem wertvoll ist

Weil wir dem Client nicht glauben müssen. Wir brauchen nur, dass **seine Lügen zueinander passen** (§13.4).

Und für den Hauptzweck — Regelbrüche — brauchen wir ihn ohnehin nur für die Optik: Die RDM/VDM-Erkennung (§13.2) läuft vollständig im Evidence-Layer.

---

<a name="5-datenmodell"></a>
## 5. Datenmodell & Binärformat

### 5.1 Grundsatz

Kein `msgpack`, kein JSON, keine Lua-Tabellen im Puffer. **`string.pack` in vorallokierte Chunk-Strings.** Begründung aus §3.6/§3.7: Eine Lua-Tabelle mit 1 Mio. Zahlen kostet zweistellige MB und muss vom inkrementellen GC **wiederholt traversiert** werden — das landet direkt in `avgTickTime`. Ein gepackter String ist **ein einziges GC-Objekt, unabhängig von seiner Größe.** Das ist der architektonische Haupthebel.

### 5.2 Tick-Record: Change-Bitmask

Jeder Tick pro Spieler beginnt mit einer 1-Byte-Maske. Nur geänderte Felder folgen.

```
Bit  Feld                    Größe   Kodierung
───────────────────────────────────────────────────────────────────
 0   Position                6 B     dx,dy,dz als i2, Zentimeter
 1   Heading                 2 B     I2, 0..65535 über 360°
 2   Kamera                  4 B     yaw I2 + pitch I2
 3   Health/Armour           2 B     I1 + I1
 4   Flags                   2 B     I2 Bitfeld (siehe 5.4)
 5   Fahrzeug                3 B     netId I2 + seat i1
 6   MoveBlend               1 B     I1, 0..255 → 0.0..3.0
 7   Extended                var     Anim-Ref, Waffe, … (siehe 5.5)
```

- **Ruhender Spieler = 1 Byte pro Tick.** Auf einem RP-Server, wo die Mehrheit steht, ist das der dominante Fall. 20 B/s statt 350.
- `dx` als `i2` in cm ⇒ ±327 m pro 50-ms-Tick ⇒ ±6,5 km/s. Weit jenseits jeder legitimen Geschwindigkeit; ein Overflow ist selbst ein Teleport-Signal (§13.1).

### 5.3 Keyframe

Etwa jede Sekunde (= 1 Chunk-Grenze) ein absoluter Keyframe. Maske = `0xFF`, Position als `i4` in cm absolut statt Delta.

```
Keyframe: ~29 B + Zeitstempel
Delta:    ~1–17 B (typisch 8–12)
```

Keyframes machen Scrubbing möglich, ohne von t=0 aufrollen zu müssen: Springe zum Chunk, lies den Keyframe, wende die Deltas bis zum Zielframe an.

> ⚠️ **Korrektur aus der Sonde (2026-07-19):** Ursprünglich stand hier „alle 20 Ticks = 1 s". **Falsch.** Gemessen ist `Wait(50)` real **~64 ms** und variabel (nicht die angenommenen 50 ms) — zwei unabhängige Timer bestätigten es. Die Sample-Rate ist also **keine feste 20 Hz**, sondern schwankt mit der Serverlast (~15 Hz im Test, unter Last weniger).
>
> **Konsequenz für das Format:** Ein Chunk darf sich **nicht** über einen impliziten Tick-Index datieren. Jeder Keyframe trägt einen **echten Zeitstempel** (`os.time()` + ms-Anteil), und die Chunk-Grenze wird über verstrichene Zeit gezogen, nicht über eine feste Tick-Zahl. Die Zahl der Deltas pro Chunk ist damit variabel. Das ist die einzige, aber wichtige Format-Änderung aus der Verifikationsphase.

### 5.4 Flags-Bitfeld (I2)

```
Bit  0  alive
Bit  1  inVehicle
Bit  2  isDriver
Bit  3  ragdoll          (IS_PED_RAGDOLL)
Bit  4  walking          (IS_PED_WALKING)
Bit  5  running          (IS_PED_RUNNING)
Bit  6  sprinting        (IS_PED_SPRINTING)
Bit  7  jumping          (IS_PED_JUMPING)
Bit  8  inCover          (IS_PED_IN_COVER)
Bit  9  aiming           (IS_PED_ARMED + Task)
Bit 10  shooting         (IS_PED_SHOOTING)
Bit 11  reloading        (GET_IS_TASK_ACTIVE CTaskReloadGun = 298)
Bit 12  falling          (CTaskFall = 423)
Bit 13  swimming
Bit 14  parachuting
Bit 15  reserved
```

Diese Booleans sind billig zu lesen und tragen den Großteil der Lokomotions-Information. Sie sind der Ersatz für das nicht existierende „gib mir die Animation".

### 5.5 Extended-Block (Bit 7)

Selten, ereignisgetrieben, nicht pro Tick:

```
0x01  animStart   : animRefId I2, flags I1, startPhase I1
0x02  animStop    : —
0x03  weaponSwitch: hash I4
0x04  clipsetChange: hash I4        (GET_PED_MOVEMENT_CLIPSET)
0x05  appearance  : appearanceId I2 (Index in die Appearance-Tabelle)
0x06  sceneChange : bucket I2
```

`animRefId` ist ein Index in eine **pro Session aufgebaute Anim-Referenztabelle** (Dict+Name+Flags → ID). So kostet eine Anim 2 Byte statt zweier Strings.

### 5.6 Chunk-Layout

```
CHUNK (1 Sekunde, 1 Spieler)
┌────────────────────────────────────────┐
│ Header (8 B)                           │
│  magic  I1  = 0xD5                     │
│  ver    I1  = 1                        │
│  tSec   I4  = Unix-Sekunde             │
│  nTicks I1  = 20                       │
│  flags  I1                             │
├────────────────────────────────────────┤
│ Keyframe (~29 B)                       │
├────────────────────────────────────────┤
│ Delta × 19 (~8–17 B je)                │
└────────────────────────────────────────┘
```

Erzeugung: 20 `string.pack`-Aufrufe in ein vorallokiertes Array, dann **ein** `table.concat` pro Sekunde pro Spieler. Ergebnis: **1 GC-Objekt pro Spieler pro Sekunde** statt 1.280.

⚠️ Niemals `buf = buf .. sample` — das ist O(n²).

### 5.7 Event-Records

Events liegen in einem eigenen Stream (nicht im Tick-Stream), weil sie unregelmäßig, größer und für die Timeline separat indizierbar sind. Als Lua-Tabellen ist das vertretbar — die Rate ist um Größenordnungen niedriger.

```lua
{
  t         = 1752633600.123,   -- os.clock()-basiert, Sub-Tick
  type      = 'damage',
  src       = 12,               -- Behauptender
  claim     = { ... },          -- weaponDamageEvent-Payload roh
  server    = {                 -- was der Server unabhängig sah
    shooterPos = vec3, victimPos = vec3, dist = 42.3,
    camYaw = 1.83               -- GET_PLAYER_CAMERA_ROTATION (yaw only!)
  },
  trust     = 'claim'           -- IMMER markiert
}
```

**Erfasste Events** (verifiziert im Routing-Switch `ServerGameState.cpp:7631` — was nicht dort steht, ist scriptseitig nicht erreichbar):

| Event | Nutzen |
|---|---|
| `weaponDamageEvent` | Kernbeweis. Alle Felder als Claim. |
| `explosionEvent` | Explosions-Spam, C4, RPG |
| `startProjectileEvent` | Wurfobjekte, Raketen |
| `giveWeaponEvent` | Waffen-Spawn-Cheats |
| `removeAllWeaponsEvent` | Disarm-Cheats |
| `entityCreating` / `entityCreated` | Entity-Spawner |
| `clearPedTasksEvent` | Anim-Cancel / Ragdoll-Abuse |
| `ptFxEvent` | Effekt-Spam |

⚠️ **`explosionEvent`-Layout ist build-abhängig** (`Is2060()`, `Is2944()`-Branches im Parser). **Build pinnen** und im Config dokumentieren.

⚠️ **`weaponDamageEvent` liefert auf manchen Builds ungültige Waffen-Hashes und immer `damageType = 0`** ([Forum](https://forum.cfx.re/t/onesync-server-weapondamageevent-does-not-behave-correctly-on-build-2060/1717489)). Nicht darauf verlassen.

🚩 **Falle, in die jeder tappt:** Der „Weapon-Hash-Mismatch"-Bug ([#3827](https://github.com/citizenfx/fivem/issues/3827)) ist keiner. `2982836145` vs. `-1312131151` sind **derselbe Hash** (signed/unsigned, Differenz exakt 2³²). Wer eine Hash-Whitelist baut, muss normalisieren:

```lua
local function normHash(h) return h < 0 and h + 0x100000000 or h end
```

---

<a name="6-recorder"></a>
## 6. Recorder (Server)

### 6.1 Sampling-Loop

```lua
-- 50 ms = exakt 1 Server-Tick. Weniger ist physisch nicht möglich (§3.2).
local TICK_MS   = 50
local CHUNK_LEN = 20    -- Ticks pro Chunk = 1 s

CreateThread(function()
    while true do
        Wait(TICK_MS)
        if Recording then sampleTick() end
    end
end)
```

### 6.2 Kostenmodell — nachrechnen, nicht raten

Pro Spieler und Tick werden **maximal** aufgerufen:

```
GetPlayerPed(src)            1
GetEntityCoords(ped)         1
GetEntityHeading(ped)        1
GetEntityHealth(ped)         1
GetPedArmour(ped)            1
GetVehiclePedIsIn(ped,false) 1
GetPlayerCameraRotation(src) 1
────────────────────────────────
                             7 Natives
```

Bei 64 Spielern × 20 Hz = **8.960 Native-Calls/s**. Die `IS_PED_*`-Booleans stehen serverseitig *nicht* zur Verfügung — die kommen aus dem Reporter (§7). Das ist der Grund für die Zweiteilung.

**Optimierungen (alle notwendig, keine optional):**

1. **Ped-Handle cachen** — `GetPlayerPed` nur bei Join/Respawn, nicht pro Tick. Spart 1.280 Calls/s.
2. **Staffelung.** Nicht alle 64 Spieler in einem Tick. Verteile auf 2 Sub-Ticks (32/32) → halbierte Peak-Tickzeit bei gleicher effektiver 20-Hz-Rate pro Spieler? **Nein** — das gäbe 10 Hz pro Spieler. Stattdessen: 20 Hz halten, aber die *teuren* Felder (Kamera) staffeln.
3. **Idle-Detection.** Bewegt sich ein Spieler seit N Ticks nicht und ist nicht im Kampf → auf 5 Hz herunterschalten. Der Change-Bitmask macht das im Format kostenlos.
4. **Kampf-Zonen-Priorität.** Spieler, für die in den letzten 10 s ein `weaponDamageEvent` existiert, werden nie gedrosselt.

### 6.3 Warum kein Node-Resource für den Recorder

Die Recherche legt nahe, dass ein Node-Server-Resource für Binärpufferung stärker wäre (echtes `Buffer`, echte Streams, echtes `fs`). **Wir machen es trotzdem in Lua**, aus drei Gründen:

1. Die Datenrate ist trivial: ~22 KB/s bei 64 Spielern. Weder Lua noch Node haben damit ein Problem. **Der Engpass ist der 50-ms-Tick und der geteilte svMain-Thread, nicht die GC.**
2. Der Lua↔JS-Übergang ist **pass-by-value** und die Doku warnt explizit vor *„significant performance cost to returning large payloads"*. Jede Grenze kostet Serialisierung.
3. Der Kunden-Codebase ist Lua/ESX. Ein Node-Resource erhöht die Support-Last (Node 16 vs. 22, `node_version`-Key, andere Fehlerbilder).

**Ausnahme:** Der optionale **Export-Pfad** (§8.4, geflaggte Incidents auf Platte/S3 schreiben) darf Node sein, weil er selten läuft und I/O-lastig ist. Dann mit **grobkörniger, gebatchter** Lua↔JS-Grenze — nie pro Sample.

---

<a name="7-reporter"></a>
## 7. Reporter (Client)

### 7.1 Was der Reporter meldet

Nur über den **eigenen** Ped. Nie über fremde — die Fokuszone (§3.8) macht fremde Daten ohnehin lückenhaft, und fremde Beobachtungen wären doppelt unzuverlässig.

```
20 Hz:
  • Flags-Bitfeld (die IS_PED_*-Booleans, §5.4)
  • MoveBlend (GET_PED_DESIRED_MOVE_BLEND_RATIO)
  • Kamera: GET_FINAL_RENDERED_CAM_ROT(2) + _FOV
  • Waffe: GET_SELECTED_PED_WEAPON (nur bei Änderung)

Ereignisgetrieben:
  • animStart/animStop (via instrumentiertem TaskPlayAnim, §12.3)
  • clipsetChange (GET_PED_MOVEMENT_CLIPSET)
  • appearance (bei Änderung, siehe 7.3)
```

**Wichtig — `GET_FINAL_RENDERED_CAM_ROT`, nicht `GET_GAMEPLAY_CAM_ROT`.** Ersteres liefert, was tatsächlich auf dem Bildschirm ist, inkl. Script-Kameras und Cutscenes. Letzteres wird falsch, sobald irgendein anderes Resource eine Cam aktiv hat — und auf einem RP-Server ist das ständig der Fall.

### 7.2 Upload

```
Batch: 20 Ticks → 1 Chunk → 1 Upload/s
Größe: ~100–200 B/s pro Spieler
Transport: TriggerServerEvent (klein genug, kein Latent nötig)
```

⚠️ **Niemals `TriggerLatentClientEvent` an `-1`.** Verifiziert: `bps` ist **per-Target**, nicht kollektiv. Broadcast an 100 Spieler mit 25 kB/s = **2,5 MB/s aggregiert**. Bekannte Issues: [#3041](https://github.com/citizenfx/fivem/issues/3041), [#1360](https://github.com/citizenfx/fivem/issues/1360) (Network-Thread-Hitches).

### 7.3 Appearance-Snapshot

Der vollständige Satz für einen MP-Freemode-Ped:

```
Model-Hash
Components 0–11  → GET_PED_DRAWABLE_VARIATION / _TEXTURE_ / _PALETTE_
Props 0–7        → GET_PED_PROP_INDEX / _PROP_TEXTURE_INDEX
HeadBlend        → GET_PED_HEAD_BLEND_DATA (struct, siehe unten)
FaceFeatures 0–19→ GET_PED_FACE_FEATURE            [CFX-Native]
Overlays 0–12    → GET_PED_HEAD_OVERLAY_DATA       [CFX-Native]
```

**Angenehme Überraschung:** `GET_PED_FACE_FEATURE` (0xBA352ADD) und `GET_PED_HEAD_OVERLAY_DATA` (0xC46EE605) **existieren als CFX-Additions** — entgegen verbreiteter Forum-Posts, die behaupten, HeadBlend sei aus Lua nicht lesbar. Diese Posts sind veraltet.

⚠️ **Struct-Falle bei `GET_PED_HEAD_BLEND_DATA`:**

```c
typedef struct {
    int shapeFirst, shapeSecond, shapeThird;
    int skinFirst, skinSecond, skinThird;
    float shapeMix, skinMix, thirdMix;
} headBlendData;   // 4 Byte Padding NACH JEDEM Feld → 8-Byte-Stride
```

In Lua über `Citizen.InvokeNative` mit korrekt dimensioniertem Buffer und 8-Byte-Stride. Das Padding ist der klassische Stolperstein.

**Caching:** Appearance ist ~90 Byte gepackt und ändert sich fast nie. Wir hashen sie und legen sie in eine Session-Tabelle; der Tick-Stream referenziert nur eine `appearanceId` (I2). Ein Kleidungswechsel = 1 Extended-Record.

**`CLONE_PED` ist keine Abkürzung** — es kopiert nur von einem *lebenden* Ped. Für Replay aus gespeicherten Daten nutzlos.

### 7.4 Der Reporter ist optional

Config-Schalter. Ohne Reporter läuft D-RPS weiter — dann eben ohne Anims, ohne Kleidung (Fallback: Default-Freemode-Ped), ohne Pitch-Aim, und der Detection-Layer verliert die Widerspruchsprüfung (§13.4).

**Wichtig:** Die **Regelbruch-Erkennung (§13.2) bleibt vollständig funktionsfähig** — sie läuft rein server-autoritativ. Ein Server, der maximale Client-Sparsamkeit will, verliert also nur Optik und Aimbot-Hinweise, nicht den Kernnutzen.

---

<a name="8-ringpuffer"></a>
## 8. Ringpuffer & Speicher

### 8.1 Struktur

```lua
-- Pro Spieler ein Ring aus Chunk-Strings. Vorallokiert, FIFO, kein realloc.
Ring[src] = {
    chunks = {},        -- [1..N] Strings, N = Config.BufferMinutes * 60
    head   = 1,         -- nächster Schreibindex
    count  = 0,
    t0     = nil,       -- Unix-Sekunde von chunks[1]
}
```

Schreiben überschreibt `chunks[head]`, `head = head % N + 1`. **Keine Allokation nach dem Warmlauf** — der alte String wird dereferenziert, der neue ersetzt ihn. Ein GC-Objekt pro Spieler pro Sekunde, sofort wieder frei.

### 8.2 Speicherrechnung

| Spieler | Rate | 15 min | 30 min | 60 min |
|---|---|---|---|---|
| 32 | 350 B/s | 10 MB | 20 MB | 40 MB |
| 64 | 350 B/s | 20 MB | **40 MB** | 81 MB |
| 128 | 350 B/s | 40 MB | 81 MB | 161 MB |
| 300 | 350 B/s | 95 MB | 189 MB | 378 MB |

Mit Idle-Drosselung realistisch **30–50 % davon** auf einem RP-Server. Default: **30 Minuten**.

⚠️ Die kursierende Behauptung „jede Resource hat ein 64–128 MB Limit" ist **unbelegt und vermutlich falsch** — sie stammt von einer nicht-affiliierten Seite ohne Quellenangabe. Im FiveM-Quellcode findet sich **kein Per-Resource-Memory-Cap.** Trotzdem: resmons Memory-Spalte liest `lua_gc(LUA_GCCOUNT)`, unser Puffer ist dort **sichtbar**. Ein Kunde, der 380 MB sieht, wird nervös — deshalb Default konservativ und die Rechnung im Config dokumentieren.

### 8.3 Was beim Neustart passiert

Nichts. Der Puffer ist weg. **Das ist eine Feature, keine Lücke** (§18 — DSGVO).

### 8.4 Disk-Persistenz: das 24h-Vollarchiv

**Anforderung (2026-07-19):** Nicht nur ein RAM-Ringpuffer für aktuelle Vorfälle, sondern ein **lückenloses Archiv des gesamten Server-Verlaufs bis zum nächsten Neustart** (z. B. der tägliche 5-Uhr-Restart). Ein Admin muss auch einen Vorfall von vor drei Stunden nachvollziehen können, nicht nur einen aus dem letzten 30-Minuten-Fenster.

Das ist für den Zweck „Regelbrüche nachvollziehen" die **überlegene Architektur** — ein gemeldeter Vorfall liegt fast nie im engen Live-Fenster.

#### Das Anti-Pattern, das NICHT gebaut wird

> „Beim Restart wird eine Datei gespeichert." — So nicht. 24h × 48 Spieler im RAM = **1–2 GB RAM nur für den Puffer** (der Testserver hat 3,8 GB total → Absturz). Und ein Crash um 4:59 verliert den ganzen Tag.

#### Stattdessen: kontinuierliches Streaming auf Disk

```
Recorder ──> RAM-Ringpuffer (nur letzte ~5 min, für Live-Detection)
         └─> Writer-Thread ──> Chunk-Datei pro Minute auf Disk
                               replay/2026-07-19/1423.chunk
                               replay/2026-07-19/1424.chunk  ...
```

- **RAM bleibt winzig** — nur das Live-Fenster, unabhängig von der Archivlänge.
- **Crash-sicher** — höchstens der letzte, noch offene Minuten-Chunk geht verloren, nie das ganze Archiv.
- **Beim Restart ist nichts zu „speichern"** — die Chunks liegen längst vollständig da. Der `onResourceStop`-Handler schließt nur den letzten Chunk sauber ab.
- **Playback lädt nie 24h auf einmal** — die App streamt das aktuelle Zeitfenster und lädt beim Scrubben nach (§9.2). Die Segment-Architektur skaliert von 30 min auf 24h **ohne Änderung**.

#### Schreibpfad — offene Verifikationsfrage

FiveM-Lua serverseitig hat `io` (sandboxed) und `SaveResourceFile`. `SaveResourceFile` überschreibt **immer die ganze Datei** (kein Append) → für einen kontinuierlichen Stream ungeeignet. Zwei Optionen:

1. **Minuten-Chunk-Dateien** via `SaveResourceFile` (jede Datei einmal komplett geschrieben) — robust, crash-sicher, kein Datei-Handle über die Zeit. **Bevorzugt.**
2. `io.open(path, 'ab')` für echtes Append — effizienter, aber Handle-Risiko und ggf. Sandbox-Einschränkungen.

→ **Verifikationsaufgabe:** Kann eine Server-Resource via `SaveResourceFile` bzw. `io` in einen Unterordner schreiben, und wie verhält sich das bei ~1 Datei/Minute dauerhaft? (§22)

#### Datenmenge

Gemessen in der Sonde: **10,5 KB/s bei 48 Spielern** (reduzierter Feldsatz, ohne Delta). Mit vollem Feldsatz + Delta + Idle-Drosselung realistisch **~15–30 KB/s** bei voller Belegung:

| Belegung | pro Tag (grob) |
|---|---|
| 48 Spieler Dauerlast | ~1,3–2,5 GB |
| RP-Server, viel Idle, gemischte Belegung | ~0,5–1 GB |

Handhabbar. Testserver hat 20 GB frei (~1 Woche). **Retention-Policy ist Pflicht** (§18).

#### Index — sonst unbrauchbar

Bei 24h braucht die App einen separaten, kleinen Index neben dem Sample-Stream:

```
replay/2026-07-19/index.json
  sessions: [ { player, identifier(pseudonym), joinT, leaveT }, ... ]
  events:   [ { t, type, pos, involved[] }, ... ]   -- Sprungmarken
```

Damit beantwortet die App „wer war um 21:34 an der Bank" und „Spieler X war 14:00–16:30 online", ohne 24h zu durchsuchen. Der Index wird ebenfalls minütlich fortgeschrieben.

#### Incident-Export bleibt

Zusätzlich zum Vollarchiv: geflaggte Incidents (t±30 s) werden als eigenständige, **von der Retention ausgenommene** `.drps`-Datei extrahiert → Discord-Webhook mit Deep-Link. Ein Incident für 30 s × 8 Spieler ≈ **85 KB** (thugs 15-s-Clip: ~5,6 MB × 2 POVs = 11 MB → **Faktor ~130**). Das ist das dauerhafte **Ban-Appeal-Archiv**, das auch eine Löschung des Tagesarchivs überlebt.

---

<a name="9-transport"></a>
## 9. Transport & Streaming

### 9.1 Das Problem

40 MB Ringpuffer lassen sich nicht an einen Admin-Client schicken. Bei 250 kB/s Latent wären das 160 Sekunden. Inakzeptabel.

### 9.2 Die Lösung: Streaming wie Video, nur in klein

```
Admin springt zu t=X
   → Client fordert Segment [X-2s, X+3s] an
   → Server filtert räumlich: nur Spieler innerhalb R des Fokuspunkts
   → Server schneidet die Chunks, packt sie, sendet sie (ein Event)
   → Client entpackt, spielt ab
   → Client prefetcht [X+3s, X+8s] während er spielt
```

**Größenrechnung:** 5-s-Segment × 8 relevante Spieler × 350 B/s = **14 KB**. Ein einziges normales Event. Kein Latent, kein Chunking, kein HTTP nötig.

Die **räumliche Filterung ist der Skalierungshebel.** Ein Kampf hat selten mehr als 10 Beteiligte, egal wie voll der Server ist.

### 9.3 Bulk-Pfad für das Web-Portal

Fürs Web-Portal ist der Weg ein anderer, weil dort ein Browser sitzt und ganze Sessions durchsucht werden:

**`SetHttpHandler` + `fetch()`, nicht `SendNUIMessage`.** Verifiziert: `SEND_NUI_MESSAGE` nimmt einen JSON-String — **jede Message kostet JSON-Encode + IPC + JS-Parse.** Für Bulk-Daten der falsche Pfad.

```lua
SetHttpHandler(function(req, res)
    -- GET /d-rps/api/segment?t=1752633600&r=120&x=..&y=..&z=..
    -- → Binär, mit Range-Support fürs Scrubbing
end)
```

Endpunkt: `http://host:30120/d-rps/...`. Erlaubt Streaming, Browser-Caching und Range-Requests.

⚠️ Der HTTP-Handler läuft **serverseitig**. Für die Ingame-NUI (die clientseitige Daten braucht) ist das kein Weg — dort bleibt es bei Events + `SendNUIMessage` für **Steuerbefehle** (play/pause/seek) und `RegisterNUICallback` für UI→Game. Die eigentlichen 3D-Daten gehen nie durch die NUI, sondern direkt an die Lua-Playback-Engine.

### 9.4 Payload-Limit

⚠️ **Offen.** Der Code prüft `totalSize >= net::packet::ReassembledEventV2::kMaxPacketSize`, aber der konkrete Wert steht in einem Net-Header, den ich nicht aufgelöst habe. Die kursierenden „32 kB oder 128 kB" sind **eine Forum-Vermutung ohne Cfx-Bestätigung.**

→ **Verifikationsaufgabe (§22).** Unsere 14-KB-Segmente liegen mit hoher Wahrscheinlichkeit sicher darunter, aber das gehört gemessen, nicht gehofft.

---

<a name="10-playback"></a>
## 10. Playback-Engine (3D)

### 10.1 Die Bühne: Routing Bucket

```lua
SetPlayerRoutingBucket(src, Config.ReplayBucketBase + sessionId)
SetRoutingBucketPopulationEnabled(bucket, false)   -- keine Ambient-NPCs/Verkehr
SetRoutingBucketEntityLockdownMode(bucket, 'strict')
```

Verifizierte Lockdown-Modi:

| Modus | Bedeutung |
|---|---|
| `strict` | Clients können **gar keine** Entities erzeugen |
| `relaxed` | Nur script-owned Client-Entities werden blockiert |
| `inactive` | Clients dürfen alles erzeugen |

**Was der Admin im leeren Bucket sieht:** Seinen eigenen Ped, die komplette Welt (Map/Props/Statics — Buckets berühren gestreamte Map-Daten nicht) und **sonst nichts Networked**. Mit Population off: keine Passanten, kein Verkehr. Eine leere Stadt.

**Das ist unsere saubere Bühne.** Der Live-Betrieb merkt nichts. Buckets filtern auch Net-Game-Events — ein Admin im Replay-Bucket kann den Live-Server nicht stören und umgekehrt.

> Anmerkung: `Config.RoutingBucketBase = 5000` ist bereits die Konvention in `d-dl`. D-RPS sollte einen **anderen** Basiswert nutzen (z. B. 9000) und das im Config dokumentieren, damit es keine Kollision gibt.

### 10.2 Klon-Peds

```lua
local ped = CreatePed(4, modelHash, x, y, z, heading, false, false)
--                                                      ^^^^^  ^^^^^
--                                            isNetwork=false, bScriptHostPed=false
```

`isNetwork = false` ⇒ **rein lokaler Ped.** Kein Netzwerkobjekt, keine Serverregistrierung, für niemand anderen sichtbar, null Netzwerkkosten. Genau das, was ein Replay-Viewer will.

`bScriptHostPed` ebenfalls `false` — ohne Networking bedeutungslos, und `true` hat gemeldete Fehler verursacht.

**Vorbereitungssequenz:**

```lua
SetEntityInvincible(ped, true)
SetBlockingOfNonTemporaryEvents(ped, true)   -- KRITISCH: sonst kapert Ambient-KI unsere Tasks
SetPedCanRagdoll(ped, false)
SetPedCanPlayAmbientAnims(ped, false)
SetPedDefaultComponentVariation(ped)
-- dann Appearance anwenden
```

⚠️ **Kollisions-Dilemma.** `SetEntityCollision(ped, false, false)` verhindert, dass Klone die Welt anrempeln — aber **ohne Kollision und ohne Freeze fällt der Ped durch die Welt.** Zwei Auswege:

- Kollision **an** lassen und das Anrempeln akzeptieren (im leeren Bucket gibt es kaum etwas zum Anrempeln — Population ist aus)
- Z explizit aus den Samples treiben

**Empfehlung: Kollision an.** Im leeren Bucket ist der Nachteil praktisch null, und wir bekommen korrektes Fußaufsetzen geschenkt.

⚠️ **`FREEZE_ENTITY_POSITION(true)` NICHT** auf einem Ped, der über Lokomotion animiert werden soll — es tötet genau die Bewegung, die wir erzeugen wollen. Nur im Scrub-Modus (§10.3).

### 10.3 Zwei Wiedergabe-Modi — die zentrale Erkenntnis

Das ist der Punkt, an dem naive Implementierungen scheitern. **Playback und Scrubbing brauchen unterschiedliche Code-Pfade.**

#### Mode A — Playback (1× / 0,5× / 2×, KI-getrieben)

Ziel: natürlich aussehende Bewegung.

```
pro Sample:
  targetPos ← nächstes Sample
  speed     ← |targetPos - currentPos| / dt
  SetPedDesiredMoveBlendRatio(ped, blendFromSpeed(speed))    -- 0/1/2/3
  ForcePedMotionState(ped, motionStateFromFlags(flags))
  TaskGoStraightToCoord(ped, targetPos, speed, timeout, heading, 0.0)
  SetPedMoveRateOverride(ped, rateToArriveOnTime)            -- Zeitdehnung

pro Frame:
  err ← |pedPos - interpolatedExpectedPos|
  if err > 0.5 then
      SetEntityCoordsNoOffset(ped, expectedPos, false, false, false)  -- keepTasks!
  end
```

Die Engine spielt echte Lokomotion mit korrektem Fußaufsetzen. `SET_PED_MOVE_RATE_OVERRIDE` streckt die Zeit, damit der Klon **pünktlich** am nächsten Sample ankommt.

⚠️ **Native-Korrektur:** `SetPedMoveRatePersonalOverride` **existiert nicht.** Das echte Native ist `SET_PED_MOVE_RATE_OVERRIDE` (0x085BF80FA50A39D1). (`_SET_PED_MOVE_RATE_IN_WATER_OVERRIDE` ist etwas anderes.)

#### Mode B — Scrub / Pause (pose-getrieben, exakt)

Ziel: exakte Position bei beliebigem t, sofort, ohne KI-Latenz.

```
FreezeEntityPosition(ped, true)
SetEntityCoordsNoOffset(ped, exactPos, false, false, false)
SetEntityHeading(ped, exactHeading)
if animRef then
    TaskPlayAnim(ped, dict, name, 8.0, -8.0, -1, flags, 0.0, false, false, false)
    SetEntityAnimCurrentTime(ped, dict, name, phase)   -- ← der Schlüssel
    SetEntityAnimSpeed(ped, dict, name, 0.0)           -- eingefroren
end
```

`SET_ENTITY_ANIM_CURRENT_TIME` (0x4487C259F0F70977) + `SET_ENTITY_ANIM_SPEED` (0x28D1A16553C51776) sind die **Sync-Primitive für framegenaues Replay**. Ohne sie gibt es kein sauberes Scrubbing.

**Modus-Übergang:** Beim Wechsel Scrub→Play muss `FreezeEntityPosition(false)` + Task-Neuaufbau erfolgen, sonst bleibt der Ped stehen. Das ist eine der Stellen, an denen der Code sorgfältig sein muss.

### 10.4 Interpolation

Bei 20 Hz **muss** interpoliert werden — rohe Samples geben sichtbares Stottern.

- **Position:** Catmull-Rom über 4 Samples (P₋₁, P₀, P₁, P₂). Kubisch, C¹-stetig, läuft durch alle Stützpunkte. Hermite wäre auch ok; lineare Interpolation reicht nicht (sichtbare Knicke bei Richtungswechseln).
- **Heading/Kamera:** **Slerp über den kürzeren Bogen** — sonst dreht sich der Ped bei einem 359°→1°-Übergang einmal komplett herum. Klassischer Bug.
- **Ragdoll:** nicht interpolieren. Ragdoll ist physikgetrieben und nicht reproduzierbar (§21.2). Beim Ragdoll-Flag hart auf Sample-Positionen schalten und die Ungenauigkeit in der UI kennzeichnen.

### 10.5 Freikamera

```lua
local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', x,y,z, rx,ry,rz, fov, true, 2)
RenderScriptCams(true, false, 0, true, false)
```

Modi:
- **Free** — WASD + Maus, Shift = schnell, Alt = langsam
- **Orbit** — um einen gewählten Spieler
- **POV** — an die aufgezeichnete Kamera eines Spielers gepinnt (aus dem Reporter; **als Client-Behauptung gekennzeichnet!**)
- **Cinematic** — `SET_CAM_ACTIVE_WITH_INTERP` zwischen Keyframes, die der Admin setzt (für Ban-Appeal-Clips)

---

<a name="11-szene"></a>
## 11. Szenen-Rekonstruktion

### 11.1 Welt-Zustand

```lua
-- Aufnahme (Client-Reporter, 1×/s reicht):
local h, m, s = GetClockHours(), GetClockMinutes(), GetClockSeconds()
local w1, w2, pct = GetWeatherTypeTransition()

-- Wiedergabe:
NetworkOverrideClockTime(h, m, s)
SetWeatherTypeTransition(w1, w2, pct)
```

**Warum `_GET/SET_WEATHER_TYPE_TRANSITION` und nicht `SET_WEATHER_TYPE_NOW`:** Das Transition-Paar rundtrippt den **exakt geblendeten** Zustand (zwei Hashes + Blend-Prozent). `SET_WEATHER_TYPE_NOW` rastet auf ein diskretes Preset und verliert jede laufende Transition. Bei einem Replay, das um 19:47 in der Dämmerung spielt, ist das der Unterschied zwischen „stimmt" und „stimmt nicht".

⚠️ Beide sind client-lokale Overrides — sie beeinflussen andere Spieler nicht. Aber: **jeden Frame neu setzen**, wenn ein Wetter-Sync-Resource dagegenhält. Auf RP-Servern ist das die Regel, nicht die Ausnahme. `NETWORK_CLEAR_CLOCK_TIME_OVERRIDE()` beim Verlassen.

### 11.2 Fahrzeuge

**Statisch (einmal pro Fahrzeug erfassen):**
```
Model-Hash, Primär-/Sekundärfarbe, Extra-Farben (Pearlescent/Wheel),
Mod-Slots 0–48 (GET_VEHICLE_MOD), Wheel-Type, Window-Tint,
Livery, Kennzeichen, Neon (an + Farbe), Xenon-Farbe
```

**Dynamisch (pro Tick):**
```
Position, Rotation, Velocity, Lenkwinkel, RPM, Gang,
Türwinkel 0–5, Lichtstatus, Engine-/Body-Health, Dirt-Level
```

⚠️ **Native-Korrektur:** `SET_VEHICLE_STEERING_ANGLE` und `SET_VEHICLE_CURRENT_RPM` sind **keine Base-Natives** — sie sind CFX-Additions und fehlen in R*-Native-Listen komplett:

```
GET_VEHICLE_STEERING_ANGLE   0x1382FCEA   [shared]
SET_VEHICLE_STEERING_ANGLE   0xFFCCC2EA   [client]
GET_VEHICLE_CURRENT_RPM      0xE7B12B54
SET_VEHICLE_CURRENT_RPM      0x2A01A8FC   [client]
```

Wer gegen eine R*-Native-Liste cross-checkt, findet sie nicht und hält sie fälschlich für nicht existent.

⚠️ **Deformation ist eine harte Lücke.** Es gibt **keinen Getter für Deformation.** `SET_VEHICLE_DAMAGE` *setzt* Schaden an einem Punkt, aber nichts liest das Deformations-Mesh zurück. Auswege:
- Skalare Health-Werte erfassen (`GET_VEHICLE_ENGINE_HEALTH`, `_BODY_HEALTH`)
- Visuellen Schaden **aus den aufgezeichneten Damage-Events approximieren** — jeden Treffer mit Offset/Damage/Radius durch `SET_VEHICLE_DAMAGE` nachspielen

**Exakte Deformations-Rekonstruktion ist nicht möglich. Das ist eine Fidelity-Decke — offen dokumentieren.**

📌 **Sackgasse dokumentiert:** GTA V hat ein eingebautes Vehicle-Recording (`START_PLAYBACK_RECORDED_VEHICLE` etc.), aber es braucht **vorgebackene `.yvr`-Carrec-Assets** und kann zur Laufzeit nicht aufnehmen. Nicht nutzbar.

### 11.3 Leichen & Tode

Der Todesmoment ist der wichtigste Frame des ganzen Systems. Ragdoll ist nicht reproduzierbar (§21.2) — deshalb:

- Ragdoll-Flag setzt einen Marker
- Ab Ragdoll: Position aus Samples, keine Interpolation, Ped auf `SetPedToRagdoll` mit eingefrorener Wurzel
- UI blendet ein: **„Ragdoll — Pose approximiert"**

Ehrlichkeit an dieser Stelle ist wichtiger als Optik. Ein Admin, der glaubt, er sähe die exakte Leichenlage, zieht falsche Schlüsse.

---

<a name="12-lokomotion"></a>
## 12. Lokomotion & Animation

Das ist die architektonisch schwierigste Stelle des Systems. §3.5 hat die Wand definiert: kein Anim-Getter, keine Bone-Setter.

### 12.1 Warum „Position pro Frame setzen" nicht funktioniert

Der häufigste Anfängerfehler, und er ist es wert, ihn zu benennen:

`SET_ENTITY_COORDS_NO_OFFSET` mit `keepTasks = false` **löscht den Task-Tree bei jedem Aufruf.** Der Ped steht in Idle, während die Position springt → das klassische Schlittern/T-Posing. Mit `keepTasks = true` ist es weniger destruktiv, aber der Motion-Tree bekommt **kein Geschwindigkeitssignal** → der Lokomotions-Blend bleibt auf 0 und der Ped gleitet in Idle-Pose.

**Positionsetzen allein animiert nicht.** Das ist der Grund, warum die meisten selbstgebauten Replays billig aussehen.

### 12.2 Der Hybrid (siehe §10.3, Mode A)

```
Treiber:      TaskGoStraightToCoord zum nächsten Sample
Blend:        SetPedDesiredMoveBlendRatio aus der BERECHNETEN Geschwindigkeit
Zustand:      ForcePedMotionState aus den aufgezeichneten IS_PED_*-Flags
Zeitdehnung:  SetPedMoveRateOverride (pünktliche Ankunft)
Korrektur:    SetEntityCoordsNoOffset(keepTasks=true) bei err > 0.5 m
Glättung:     Catmull-Rom Interpolation zwischen Samples
```

Motion-State-Hashes für `FORCE_PED_MOTION_STATE`: `CTaskMotionIdle`, `CTaskHumanLocomotion`, `CTaskMotionAiming`, `CTaskNMHighFall`. Via `GetHashKey`.

⚠️ Semantik des `updateState`-Parameters von `FORCE_PED_MOTION_STATE` ist **undokumentiert** → empirisch bestimmen.

### 12.3 Animationen: an der Quelle instrumentieren

Da es keinen Getter gibt, ist der einzige verlässliche Weg, den **Aufruf** abzufangen.

**Für eigene Resources** — ein Wrapper, den auch `d-dl` und `md_wunden` nutzen können:

```lua
-- exports['d-rps']:PlayAnim(ped, dict, name, blendIn, blendOut, dur, flags)
-- → ruft TaskPlayAnim UND loggt dict/name/flags/startTime in den Recorder
```

**Für Fremd-Resources** — ein öffentliches Export, das wir bewerben:

```lua
exports['d-rps']:RegisterAnim(dict, name, flags)   -- meldet eine laufende Anim an
exports['d-rps']:UnregisterAnim(dict, name)
```

Das ist gleichzeitig ein **Verkaufsargument**: „Integrierbar in jedes Resource mit einer Zeile."

**Für alles andere** — eine kuratierte Allowlist häufiger Dicts (Handzeichen, Emotes, `mp_common`, Waffenanims), gegen die wir `IsEntityPlayingAnim` pollen.

⚠️ **Das skaliert nicht.** Forum-Berichte melden Lag beim breiten Scannen. **Harte Grenze: max. 20 Einträge in der Allowlist, gepollt mit 5 Hz, nur wenn der Ped nicht in Standard-Lokomotion ist.** Das gehört in den Config mit einem deutlichen Kommentar.

### 12.4 `GET_PED_MOVEMENT_CLIPSET` — ein Fund

```
GET_PED_MOVEMENT_CLIPSET(ped) -> int      0x69E81E3D   [CFX, client]
```

**Existiert**, obwohl Forum-Threads es bis heute als Feature-Request führen. Damit bekommen wir benutzerdefinierte Bewegungsstile (Gangster-Walk, Verletzten-Humpeln — auch `md_wunden` setzt so etwas) kostenlos ins Replay.

⚠️ **Unklar:** Gibt es den Clipset-Hash oder einen internen Index zurück? Was bei Default/unset? Beschreibung in der DB ist leer. → **Verifikationsaufgabe (§22).**

### 12.5 Was wir nicht bekommen — offen sagen

Animationen aus Fremd-Resources, die weder unser Export nutzen noch auf der Allowlist stehen, sind **unrekonstruierbar**. Der Klon fällt auf Standard-Lokomotion zurück.

**Das gehört in die Produktbeschreibung, nicht ins Kleingedruckte.** Ein Käufer, der das nach dem Kauf entdeckt, macht ein Refund-Ticket auf. Ein Käufer, der es vorher liest, integriert unser Export und ist zufrieden.

---

<a name="13-detection"></a>
## 13. Detection-Layer

### 13.1 Der Reality-Check zuerst

Bevor wir irgendetwas versprechen — vier verifizierte Fakten, die die Erwartung kalibrieren:

1. **FiveM ist client-autoritativ.** Offizielle Doku: *„Server-based authoritative ownership models used by some other multiplayer platforms do not exist in the same way in FiveM."* OneSync fügt Sichtbarkeit/Routing/Creation-Gating hinzu — es verschiebt Simulation **nie** auf den Server.

2. **Serverseitige LOS-Prüfung ist unmöglich**, nicht nur fehlend: kein Shapetest-Native ist serverseitig registriert (§3.4).

3. **Beide Seiten jeder Kamera-vs-Damage-Prüfung sind vom Schützen verfasst.** Die serverseitige Kamera ist client-verfasste Sync-Data mit 0,35° Auflösung und **verworfenem Pitch**.

4. **Der wichtigste Befund überhaupt:** Witschel & Wressnegger, [„Aim Low, Shoot High"](https://arxiv.org/abs/2004.12183), EuroSec '20 — ein Aimbot, der auf **+5 % Leistungsgewinn** getunt war, blieb über **60 offizielle Matches** von SMAC, COW **und** VAC+VACnet+Overwatch unentdeckt. Jeder Schwellwert-Detektor der Welt ist gegen *plumpes* Cheaten kalibriert.

**Konsequenz für die Produktkommunikation:** D-RPS ist **Beweismaterial für menschliche Prüfung**, kein Beweis. Wer etwas anderes verspricht, lügt — und bekommt es als Refund zurück.

> **Aber:** Der Absatz oben gilt für *Cheat*-Erkennung. Für den eigentlichen Zweck dieses Produkts — **Regelbrüche** — ist die Lage deutlich besser. Siehe §13.2.

### 13.2 Regelbrüche — der eigentliche Kern

**Das ist der Primärzweck von D-RPS.** Nicht Aimbots, sondern RDM, VDM, Combat-Logging und Fail-RP: die Fälle, mit denen RP-Admins tatsächlich ihre Zeit verbringen.

Und hier liegt ein glücklicher Umstand: **Regelbruch-Erkennung braucht kein Client-Vertrauen.**

Die zentrale Frage bei RDM lautet: *„Gab es vorher eine Interaktion zwischen A und B?"* Das beantwortet sich vollständig aus Daten, die der Server unabhängig sieht — Nähe, Zeit, Chat-Reichweite, vorheriger Schaden. Anders als beim Aimbot gibt es hier **keinen fundamentalen Vertrauensbruch.** Ein Cheater kann seinen Aim fälschen; er kann nicht fälschen, dass er 4 Minuten lang 200 m von seinem Opfer entfernt war.

> **Kernerkenntnis:** Der schwierigste Teil des Systems (§13.4, Widerspruchsprüfung) ist für den Hauptzweck **nicht kritisch**. Er wird vom Kernfeature zum Bonus. Das senkt das Projektrisiko erheblich.

#### 13.2.1 Der Interaktions-Graph

Die Datenstruktur, die alles trägt. Für jedes Spielerpaar (A, B) wird ein gleitendes Fenster geführt:

```lua
Interaction[a][b] = {
    lastProximity   = t,      -- zuletzt < Config.ProximityMeters entfernt
    proximitySecs   = 0,      -- kumulierte Sekunden in Nähe (letzte 10 min)
    lastChatInRange = t,      -- A hat in B's Reichweite geschrieben (o. umgekehrt)
    lastVoiceInRange= t,      -- A hat in B's Reichweite gesprochen
    lastDamage      = t,      -- Schaden in EINE der beiden Richtungen
    damageCount     = 0,
    sharedVehicle   = t,      -- saßen im selben Fahrzeug
    firstSeen       = t,
}
```

**Kosten:** O(n²) im Worst Case, aber nur für Paare **innerhalb** von `Config.ProximityMeters` (Default 50 m). Auf einem 64er-Server sind das typisch 20–60 aktive Paare, nicht 2.016. Aktualisiert mit 2 Hz (nicht 20 — Nähe ändert sich langsam), Einträge älter als 10 min werden verworfen.

Das ist der einzige nennenswerte Zusatzaufwand gegenüber dem Basis-Konzept, und er ist billig.

#### 13.2.2 RDM (Random Deathmatch)

```
Trigger:  weaponDamageEvent A -> B, willKill oder Health B faellt unter Schwelle

Ruecklauf ueber Interaction[A][B] und Interaction[B][A]:
  ✓ proximitySecs        == 0 in den letzten 5 min?
  ✓ lastChatInRange      == nil?
  ✓ lastVoiceInRange     == nil?
  ✓ lastDamage           == nil (keine Vorgeschichte)?
  ✓ Distanz beim Schuss  > Config.RdmMinDistance?

Alle fünf → RDM-Kandidat, Konfidenz hoch
Vier      → RDM-Kandidat, Konfidenz mittel
```

**Warum das gut funktioniert:** Legitimes RP hat *immer* einen Vorlauf. Ein Raub hat Ansprache, ein Konflikt hat Eskalation, eine Verfolgung hat Nähe. Ein Spieler, der jemanden erschießt, mit dem er in den letzten fünf Minuten **null** Berührungspunkte hatte, ist der klassische RDM-Fall — und das Signal ist server-autoritativ.

**Bekannte Falsch-Positive**, die der Config abfangen muss:
- Fraktions-/Gang-Konflikte mit Vorgeschichte außerhalb des Fensters → `Config.RdmLookbackMinutes` hochsetzen
- Polizei-Einsätze (Schusswechsel ohne persönliche Vorgeschichte) → Job-Whitelist über die Bridge
- Green-Zone-Regeln, Kriegsgebiete, Events → `exports['d-rps']:SetRuleZone(zone, ruleset)`
- Crossfire (A zielt auf C, trifft B) → `hitGlobalIds` prüfen, Winkel zum eigentlichen Ziel

#### 13.2.3 VDM (Vehicle Deathmatch)

```
Trigger:  weaponDamageEvent mit weaponType == WEAPON_RUN_OVER_BY_VEHICLE
                                          oder WEAPON_RAMMED_BY_VEHICLE

Signale (alle server-autoritativ):
  • Fahrzeuggeschwindigkeit beim Aufprall
  • Lenkwinkel-Verlauf der letzten 2 s   → hat A auf B ZUGESTEUERT?
  • Kursänderung Richtung B              → Winkel(Kurs, B-A) verengt sich?
  • Bremsspur / Verzögerung              → oder eben KEINE
  • Interaktions-Graph wie bei RDM
  • Wiederholung: mehrere Anfahrten in kurzer Folge
```

**Der Lenkwinkel-Verlauf ist das stärkste Signal und der Grund, warum wir ihn pro Tick aufzeichnen.** Ein Unfall hat Bremsen und Ausweichen. Ein VDM hat eine sich verengende Kurskorrektur auf das Ziel zu, ohne Verzögerung. Das ist im Replay sichtbar — und quantifizierbar.

`GET_VEHICLE_STEERING_ANGLE` (0x1382FCEA) ist ein CFX-Native mit `apiset = shared` — **serverseitig aufrufbar.** Das ist ein Glücksfall: Das wichtigste VDM-Signal liegt im Evidence-Layer, nicht im Fidelity-Layer.

#### 13.2.4 Combat-Logging

Der billigste und eindeutigste Detektor im ganzen System:

```
playerDropped innerhalb Config.CombatLogSeconds (Default 60) nach
  Schaden gegeben ODER Schaden genommen
→ Flag, Konfidenz hoch, mit Incident-Export
```

Zusätzlich unterscheidbar über den Drop-Grund: `Exiting`/`Quit` (bewusst) vs. `Timed out` (evtl. echter Verbindungsabbruch). Beides flaggen, aber getrennt kennzeichnen — ein Timeout ist kein Regelbruch, sondern Pech, und der Admin muss das unterscheiden können.

Das ist ein Fall, in dem D-RPS dem Kunden **ab Tag 1** Arbeit abnimmt, ganz ohne 3D.

#### 13.2.5 Weitere Kandidaten

| Regelbruch | Signal | Konfidenz |
|---|---|---|
| **Spawn-Kill** | Damage < N s nach Respawn/Join | hoch |
| **Safezone-Verstoß** | Damage-Event innerhalb Zonen-Polygon | hoch |
| **Combat-Storing** | Inventar-/Fahrzeug-Aktion während Kampf (via `LogEvent`) | mittel |
| **NLR-Verstoß** (New Life Rule) | Spieler kehrt < N min nach Tod an den Todesort zurück | hoch |
| **Cop-Baiting** | wiederholte Provokation ohne RP-Vorlauf | niedrig |
| **Powergaming / Fail-RP** | ❌ nicht erkennbar | — |
| **Metagaming** | ❌ prinzipiell nicht erkennbar (Discord ist außerhalb) | — |

**NLR ist unterschätzt** und praktisch geschenkt: Todesort ist bereits aufgezeichnet, Rückkehr ist ein Distanz-Check. Ein Feature, das kein Wettbewerber hat, für ~20 Zeilen Code.

#### 13.2.6 Was der Detektor *nicht* kann — und warum das egal ist

Fail-RP und Powergaming sind **nicht algorithmisch erkennbar.** Sie sind Urteilsfragen.

**Aber genau dafür ist das 3D-Replay da.** Der Wert für diese Fälle liegt nicht in der Erkennung, sondern darin, dass ein Admin einen gemeldeten Vorfall in 30 Sekunden aus jedem Winkel nachvollziehen kann — statt drei Beteiligte zu befragen und drei Versionen zu bekommen.

> **Das ist die eigentliche Produktthese:** D-RPS erkennt, was erkennbar ist, und macht den Rest *überprüfbar*. Die Detection füllt die Warteschlange; das Replay leert sie.

#### 13.2.7 Was das für die Datenerfassung zusätzlich bedeutet

Der Interaktions-Graph braucht zwei Datenquellen, die im Basis-Konzept fehlten:

**Chat.** Für die RDM-Vorgeschichte ist Chat der wichtigste Kontext.
```lua
AddEventHandler('chatMessage', function(src, name, msg) ... end)
-- Nur: Zeitpunkt, Sender, Position, Reichweite. Der TEXT ist optional.
```
⚠️ **Config-Schalter `Config.RecordChatText`, Default `false`.** Der *Zeitpunkt* einer Nachricht in Reichweite reicht für die Interaktionsprüfung völlig. Der Inhalt ist personenbezogener als alles andere im System (§18) und für die Heuristik nicht nötig. Wer ihn will, schaltet ihn bewusst ein.

**Voice.** Wir zeichnen **kein Audio** auf — nur, *dass* jemand gesprochen hat, und in wessen Reichweite.
```lua
-- pma-voice / mumble: Sprech-Zustand via State Bag
Player(src).state.talking   -- oder MumbleIsPlayerTalking clientseitig
```
Damit erkennen wir „A und B standen 40 Sekunden zusammen und haben geredet" — der klarste Beleg gegen RDM, den es gibt. Ohne einen einzigen Ton zu speichern. Das ist datenschutzrechtlich der Unterschied zwischen einem Feature und einem Problem.

⚠️ **Verifizieren:** Ob der Sprech-Zustand serverseitig verfügbar ist, hängt vom Voice-Resource ab (pma-voice, mumble-voip, saltychat haben unterschiedliche APIs). → Bridge-Adapter, mit Fallback „Voice-Signal nicht verfügbar" statt Fehler.

### 13.3 Was wir sicher fangen (Evidence-Layer, server-autoritativ)

| Cheat | Signal | Konfidenz |
|---|---|---|
| **Teleport** | `dx` überschreitet den i2-Bereich, oder Δpos > v_max × dt | hoch |
| **Speedhack** | gleitende Geschwindigkeit > Fahrzeug-/Fußmaximum | hoch |
| **Godmode** | Damage-Claims gegen Ziel, Health unverändert über N Ticks | hoch |
| **Entity-Spawn** | `entityCreated`-Rate pro Source | hoch |
| **Waffen-Spawn** | `giveWeaponEvent` ohne vorangehende Server-Transaktion | hoch |
| **Explosion-Spam** | `explosionEvent`-Rate pro Source | hoch |
| **Noclip** | Position innerhalb Kollisionsgeometrie (via Replay-Raycast, §13.5) | mittel |

Diese Klassen sind **belastbar**, weil sie auf Daten beruhen, die der Server unabhängig sieht bzw. deren Fälschung zusätzliche, ebenfalls sichtbare Widersprüche erzeugt.

### 13.4 Was wir teilweise fangen: die Widerspruchsprüfung

**Der eigentliche Trick des Systems.** Wir vertrauen dem Client nicht — wir prüfen, ob **seine Behauptungen zueinander passen.**

```
Client-Reporter sagt:        Kamera zeigt bei t auf Azimut θ_cam (Yaw+Pitch, 20 Hz)
weaponDamageEvent sagt:      Treffer auf Opfer bei Position P_v, impactDir = D
Server sah unabhängig:       Schütze bei P_s, Opfer bei P_v

Prüfung 1 (Silent Aim):   Winkel(θ_cam, P_v - P_s) > Schwelle?
Prüfung 2 (ImpactDir):    Winkel(D, P_v - P_s) inkonsistent?
Prüfung 3 (Snap):         dθ_cam/dt-Spitze in den 100 ms vor dem Schuss?
Prüfung 4 (Multi-Hit):    #hitGlobalIds > 1 bei einem Einzelschuss?
```

**Warum das funktioniert:** Silent Aim ist per Definition ein Widerspruch — der ganze Sinn ist, dass sich der Bildschirm des Spielers *nicht* bewegt. Der Cheat erzeugt die Inkonsistenz selbst.

**Warum es nicht immer funktioniert:** Ein Cheater kann unseren Reporter fälschen und einen Fake-Aim melden, der aufs Opfer zeigt. Dann müsste er allerdings **menschlich aussehende Mausbewegung simulieren** — Beschleunigungskurve, Overshoot, Mikrokorrekturen. Das ist eine andere Liga als eine Zahl zu fälschen.

**Präzedenz aus Minecraft — vollständig verifiziert und direkt übertragbar:** LiquidBounces `RotationManager` hält `currentRotation` (Kamera) getrennt von `actualServerRotation` (gesendet). Die Doku beschreibt `MovementCorrection`: **Off** — *„can be detected by anti-cheats because the movement direction will not match the server-side head rotation"*; **Strict/Silent** — korrigiert die Bewegung passend zur server-seitigen Rotation, um **genau dieses Artefakt zu verstecken**.

Mit anderen Worten: **Die Widerspruchsprüfung ist real und wirksam — und es gibt eine bekannte Gegenmaßnahme.** Sie fängt die 95 %, die Standard-Cheats nutzen; sie verliert gegen die, die es auf dich persönlich abgesehen haben. Das ist derselbe Ort, an dem Minecraft-Anticheats landen. Kein Scheitern — der Normalzustand.

### 13.5 Der LOS-Trick — unser Novum

Der Server **kann** nicht raycasten (§3.4). Aber:

> **Der Admin-Client kann. Während des Replays.**

Wir rekonstruieren die Szene ohnehin. Also legen wir bei der Wiedergabe einen Shapetest vom Schützen zum Opfer über die tatsächliche Weltgeometrie:

```lua
-- Auf dem Admin-Client, während der Incident-Wiedergabe:
local ray = StartShapeTestRay(shooterHeadPos, victimPos, 1|16, victimPed, 0)
local _, hit, endCoords, _, entityHit = GetShapeTestResult(ray)
if hit == 1 and entityHit ~= victimPed then
    -- Der Schuss ging durch Geometrie. Wand-Hit.
end
```

Damit prüfen wir **retroaktiv**, was der Server live nie prüfen konnte. Das ist keine Live-Detection — es ist **Beweisverstärkung im Review**, und genau dort, wo der Admin ohnehin hinschaut.

**Nach meiner Kenntnis macht das kein FiveM-Produkt.** Es ist der stärkste technische Differenzierer im ganzen Konzept.

⚠️ Einschränkung: Die Weltgeometrie auf dem Admin-Client muss der zum Tatzeitpunkt entsprechen. Bei MLOs, die zur Laufzeit geladen/entladen werden, oder Türen/Objekten, deren Zustand wir nicht aufzeichnen, kann das abweichen. → Als **Hinweis** kennzeichnen, nicht als Beweis. Und Tür-/Objektzustände in einer späteren Version mit aufzeichnen.

### 13.6 Was der Wettbewerb liegen lässt

Verifiziert: **Genau ein offener, lesbarer Aimbot-Detektor existiert** — Icarus' `AimbotModule.ts`. Er nimmt bei `weaponDamageEvent` den Kamera-Yaw, verlängert den Forward-Vektor auf Opferdistanz und flaggt bei > 7,0 Units Abweichung. Er ist **standardmäßig deaktiviert**, **nur 2D**, schließt Fahrzeuge aus (*„Not exactly sure why, but vehicles make this detection method inaccurate"*), und der Autor schrieb wörtlich `// Why does that work? I have no idea`.

Und es ist ein **Silent-Aim-Detektor, kein Aimbot-Detektor** — ein echter Aimbot, der die Kamera aufs Ziel snappt, geht sauber durch.

**Ungenutzte Felder, die niemand ausliest:**

| Feld | Ungenutztes Potenzial |
|---|---|
| `hitGlobalIds[]` | Array — ein Schuss, der mehrere Opfer trifft, wird **nie** geprüft |
| `impactDirX/Y/Z` + `hasImpactDir` | Client-gemeldete Treffer-Richtung, gegen Schütze→Opfer-Vektor prüfbar |
| `damageFlags` | ungenutzt |
| `hitComponent` | Trefferzone → Headshot-Quote über Zeitfenster |

Außerdem: **Niemand macht Waffen-spezifische Reichweiten-Validierung.** `rw-anticheat` nutzt ein pauschales `dist > 600.0` — und der eigene Kommentar räumt ein, dass das reale Limit bei ~250–300 m liegt. **Niemand rate-limitet Schusswaffen.**

Das ist reichlich unbestelltes Feld.

### 13.7 Das Verdikt-Modell: VACnet, nicht Auto-Ban

**Bester Präzedenzfall — VACnet** (McDonald, GDC 2018, „Robocalypse Now"): *„effective at identifying cheating behavior without any client-side instrumentation"*, bestimmte Cheats *„um den Faktor einhundert"* reduziert.

Die zwei Eigenschaften, die es funktionieren ließen, waren **nicht** das neuronale Netz:
1. **Training auf menschlich gelabelten Verurteilungen** (Overwatch)
2. **Flaggen zur Prüfung statt Auto-Ban**

Beides ist in FiveM erreichbar.

Ebenfalls kopierenswert aus CS:GO Overwatch: Reviewern wird *„a replay of a randomly selected eight-round segment"* gezeigt — **Chat entfernt, Namen anonymisiert**, mit einem expliziten **„Insufficient Evidence"**-Verdikt. Zwei Designentscheidungen, die wir übernehmen:

- **Evidence Minimization** — der Reviewer sieht nur, was nötig ist
- **Explizite Unsicherheit** — „nicht genug Beweise" ist ein *gültiges*, sichtbares Ergebnis, kein Durchfallen

**D-RPS bannt niemanden. Nie.** Es erzeugt Incidents mit einem Konfidenz-Score und einem Deep-Link ins Replay. Der Mensch entscheidet.

Das ist auch juristisch und produktpolitisch die einzige haltbare Position: Ein Auto-Ban-System, das Falsch-Positive produziert, kostet den Kunden Spieler — und uns den Ruf.

### 13.8 Falsch-Positive: die bekannte Falle

Verifiziert: Screen-Effekt-Resources erzeugen Falsch-Positive. Icarus' eigener Config: *„In case you use any 'drug effects' or 'drunk' resources increase this value gradually."*

Auf einem RP-Server sind Drogen-/Alkohol-Effekte, Verletzungs-Kameraschütteln (**`md_wunden` macht genau das**) und Cutscene-Kameras normal. Unsere Kamera-Heuristiken **müssen** das wissen.

→ **Config-Whitelist für Resources, die die Kamera manipulieren**, plus ein Export, mit dem ein Resource sich temporär abmelden kann:

```lua
exports['d-rps']:SuppressCameraChecks(playerId, durationMs, reason)
```

---

<a name="14-ui"></a>
## 14. Admin-UI: Ingame & Web

### 14.1 Ingame (React + Vite + Tailwind — wie `md_wunden`)

```
┌────────────────────────────────────────────────────────────────┐
│  ⏮  ⏸  ⏭    0.25× 0.5× 1× 2× 4×      14:23:07 / 14:53:07     │
├────────────────────────────────────────────────────────────────┤
│ ▓▓▓▓▓░░░░░░░░●░░░░░░░░░░░░░░░░▲░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│      ↑Kill        ↑jetzt      ↑Flag: Silent Aim (Konf. 0.72)   │
├──────────────────────┬─────────────────────────────────────────┤
│ SPIELER (8)          │  INCIDENT #4471                         │
│ ● Max_Mustermann  ⚑  │  Typ:     Silent Aim (Verdacht)         │
│ ● Anna_Beispiel      │  Quelle:  ⚠ Client-Behauptung           │
│ ○ Tom_Test (tot)     │  Winkel:  47.3° Abweichung              │
│ ...                  │  LOS:     ✗ durch Geometrie             │
│                      │  Konfidenz: ▓▓▓▓▓▓▓░░░ 0.72             │
│ [Kamera: Frei ▾]     │  [Zum Zeitpunkt] [Exportieren]          │
└──────────────────────┴─────────────────────────────────────────┘
```

**Vertrauens-Kennzeichnung ist Pflicht, nicht Deko.** Jedes Datum trägt sichtbar sein Herkunftssiegel:

- 🛡 **Server** — autoritativ
- ⚠ **Client-Behauptung** — spoofbar

Ein Admin, der das nicht sieht, zieht falsche Schlüsse. Diese zwei Icons sind das ehrlichste Feature des Produkts.

### 14.2 Web-Portal

```
SetHttpHandler → /d-rps/
   ├── /              2D-Karten-Viewer (Leaflet + GTA-V-Map-Tiles)
   ├── /api/sessions  Liste der Aufnahmefenster
   ├── /api/segment   Binär, Range-Support
   ├── /api/incidents Detection-Flags
   └── /api/export    .drps-Download
```

Der 2D-Viewer ist **billig und überraschend nützlich**: Blips auf der Karte, Timeline, Event-Marker, Klick → Deep-Link ins Ingame-Replay. Für „wer war um 21:34 an der Bank" braucht niemand 3D.

**Auth:** Token, serverseitig generiert, zeitlich begrenzt. **Niemals** auf `ACE`-Permission vom Client vertrauen. Rate-Limit auf allen Endpunkten.

⚠️ **Der HTTP-Handler ist über die Server-IP:Port erreichbar.** Das ist ein Angriffspunkt. Default: **deaktiviert**, im Config mit deutlicher Warnung zum Aktivieren + dringender Empfehlung eines Reverse-Proxy mit TLS.

### 14.3 Escrow-Realität

§3.10: **NUI kann nicht escrowed werden.** Unsere React-App liegt beim Kunden im Klartext.

**Konsequenz für die Produktarchitektur:** Die UI darf **keinen** Geschäftswert tragen. Kein Detection-Algorithmus im JS, keine Formatlogik, keine Heuristik-Schwellen. Die UI ist ein dummer Renderer für das, was Lua ihr schickt. Der Wert sitzt im escrowbaren Lua: Format, Recorder, Ringpuffer, Detection.

---

<a name="15-performance"></a>
## 15. Performance-Budget

### 15.1 Verbindliche Ziele

| Komponente | Ziel | Hartes Limit | Quelle |
|---|---|---|---|
| Reporter (Client, jeder Spieler) | **< 0,10 ms** avg | 1,0 ms (grün) | resmon-Farbrampe |
| Playback (Client, nur Admin) | **< 2,0 ms** avg | 6,0 ms (Warnung) | `ResourceMonitor.cpp` |
| Recorder (Server) | **< 1,5 ms** / Tick @ 64 | 150 ms (Hitch) | `GameServer.cpp` |
| Ringpuffer RAM @ 64 / 30 min | **< 50 MB** | — | eigene Rechnung |
| Netz pro Spieler | **< 0,5 KB/s** | — | eigene Rechnung |
| Netz pro Admin-Session | **< 20 KB/s** | — | eigene Rechnung |

**Der Reporter ist die kritische Zahl.** Er läuft bei *jedem* Spieler, permanent. thugs Marketing behauptet „extremely low resmon" für ein Script, das VP9 encodiert — bei uns muss die Zahl echt sein, weil wir genau damit werben.

### 15.2 Nicht verhandelbare Regeln

1. **Kein `Wait(0)`** außer im Playback-Renderloop des Admins.
2. **Natives aus Schleifen hoisten.** Bestätigt: Natives gehen durch den Native-Handler und marshallen Argumente über die Runtime-Grenze — *„way slower than using crossmap"* ([#2878](https://github.com/citizenfx/fivem/issues/2878)). **Native-Calls sind die dominanten Kosten in jeder engen Schleife.** Cachen.
3. **Backtick-Hash-Literale** — `` `weapon_pistol` `` wird **zur Compile-Zeit** Jenkins-OAAT-gehasht. Eliminiert `GetHashKey` zur Laufzeit. Kostenloser Gewinn, überall anwenden.
4. **`PlayerPedId()` cachen** — pro Frame einmal, nicht pro Aufruf.
5. **Keine Allokation pro Sample.** Vorallokierte Arrays, `string.pack`, `table.concat` in Batches.
6. **Kein `msgpack`/`json` im heißen Pfad.** Nur für Config und Events.
7. **Nie an `-1` broadcasten**, weder latent noch normal.
8. **Squared Distance**, `math.sqrt` nur auf dem Gewinner. (Ist bereits `md_wunden`-Konvention.)

### 15.3 Messen, nicht glauben

**`profiler record <frames>` → `profiler view`** ist das echte Werkzeug — client (F8) und Serverkonsole, `profiler saveJSON` für Offline-Analyse.

> **resmon sagt dir *dass* du langsam bist. Der Profiler sagt dir *wo* — bis auf Datei und Zeile.**

Vor jedem Release: Profiler-Lauf bei 64 simulierten Spielern, Ergebnis ins Changelog. Das ist ein Verkaufsargument, das kein Wettbewerber liefert.

⚠️ Die kursierenden „0,1–0,4 ms idle / 0,25–0,5 ms verdächtig"-Zahlen stammen **ausschließlich von Hosting-SEO-Blogs**, nicht von Cfx. Richtungsweisend plausibel, aber **nicht als Autorität zitieren.** Die einzige im Code verankerte Definition ist: grün < 1,0 ms, Warnung bei 6,0 ms avg über 64 Ticks.

---

<a name="16-sicherheit"></a>
## 16. Sicherheit & Anti-Tamper

### 16.1 Bedrohungsmodell

| Angreifer | Ziel | Gegenmaßnahme |
|---|---|---|
| Cheater | Reporter fälschen, um sauber auszusehen | Widerspruchsprüfung (§13.4); Reporter ist Fidelity, nicht Evidence. Regelbruch-Erkennung ist davon **nicht** betroffen (§13.2). |
| Cheater | Reporter abschalten | Heartbeat; fehlender Reporter = eigener Flag |
| Cheater | Recorder mit Müll fluten | Rate-Limit pro Source; Whitelist-Validierung |
| Neugieriger Spieler | Replay-Daten anderer sehen | Serverseitige ACE-Prüfung auf **jedem** Event |
| Konkurrent | Format reversen | Escrow (begrenzt, §16.3) |

### 16.2 Serverseitige Validierung — nach `md_wunden`-Konvention

Der bestehende Stil ist genau richtig und wird übernommen:

- **Whitelist-Tabellen statt Pattern-Checks** (`VALID_TYPES`, `VALID_ZONES` → `O(1)`-Membership)
- **Rate-Limits pro Source**, verschachtelt wenn ein Ziel beteiligt ist
- **Caps** auf Listenlängen
- **Server-seitige Proximity-Checks** mit quadrierter Distanz
- **Permission bei jedem Callback neu prüfen**, nie vom Client trauen
- **Debug hart gaten:** `if not Config.Debug then return end`; Konsole-only: `if source ~= 0 then return end`
- **`pcall(json.decode, ...)`** um alles aus der DB

Zusätzlich für D-RPS:

```lua
-- Reporter-Payload: Größe VOR dem Unpack prüfen
if #payload > MAX_REPORT_BYTES then
    Flag(src, 'reporter_oversized', #payload)
    return
end
-- Magic + Version prüfen, dann erst string.unpack in pcall
```

**Ein fehlerhafter Reporter-Payload darf niemals den Recorder werfen.** Sonst ist D-RPS selbst der DoS-Vektor.

### 16.3 Escrow — ehrliche Einschätzung

Verifiziert: Escrow ist **entitlement-basiert, nicht Obfuskation**. Und es ist **im Plattform-Maßstab gebrochen** — nach Cfx' eigenen Eingeständnissen:

- [Juli 2022 — Bytecode-Dump](https://forum.cfx.re/t/addressing-recent-asset-escrow-exploit/4879802): Cfx wörtlich *„nowhere close to the original source code"*
- [August 2025 — client-seitige Asset-Extraktion](https://forum.cfx.re/t/asset-security-update/5344773)
- Oktober 2025 — Eingeständnis, dass *„no encryption method can be rendered completely impenetrable."*

**Beide Stufen leaken.** gfx-deathcam liegt auf VAG und HighLeaks. Der Unterschied ist nicht *ob*, sondern die **Qualität** des Leaks: Escrow-Leaks sind niedrigauflösender Bytecode mit einem Entitlement-Backstop; Open-Source-Leaks sind perfekt und ohne Gegenmittel.

→ **Realistische Erwartung, keine Illusion.** Escrow verlangsamt, es schützt nicht.

---

<a name="17-integration"></a>
## 17. Integration: Config, Bridge, Exports

### 17.1 Struktur (nach bestehender Konvention)

```
D-RPS/
  fxmanifest.lua
  shared/config.lua          -- escrow_ignore
  shared/locale.lua          -- _L()-Engine
  shared/protocol.lua        -- Format-Konstanten, geteilt
  locales/de.lua, en.lua     -- escrow_ignore
  bridge/shared.lua
  bridge/client.lua
  bridge/server.lua
  client/reporter.lua
  client/playback.lua
  client/scene.lua
  client/camera.lua
  client/nui.lua
  client/main.lua            -- zuletzt laden
  server/ringbuffer.lua
  server/recorder.lua
  server/events.lua
  server/detection.lua
  server/session.lua
  server/http.lua
  server/main.lua
  ui/                        -- React + Vite + Tailwind, dist/ committed
  README.md
  OVERVIEW.md
  D-RPS_Installation.txt
```

### 17.2 fxmanifest

```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'D-RPS'
description 'Dollar Replay System — 3D State Replay & Admin Evidence'
version '0.1.0'
author 'Dollar Development'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/locale.lua',
    'shared/protocol.lua',
    'locales/*.lua',
    'bridge/shared.lua',
}

client_scripts {
    'bridge/client.lua',
    'client/reporter.lua',
    'client/scene.lua',
    'client/camera.lua',
    'client/playback.lua',
    'client/nui.lua',
    'client/main.lua',
}

server_scripts {
    'bridge/server.lua',
    'server/ringbuffer.lua',
    'server/recorder.lua',
    'server/events.lua',
    'server/detection.lua',
    'server/session.lua',
    'server/http.lua',
    'server/main.lua',
}

ui_page 'ui/dist/index.html'
files { 'ui/dist/**' }

escrow_ignore {
    'shared/config.lua',
    'locales/*.lua',
    'ui/dist/**',        -- kann ohnehin nicht escrowed werden (§3.10)
}

dependencies { 'ox_lib' }
```

> **Bewusste Entscheidung: kein `es_extended` in `dependencies`.** D-RPS läuft **standalone**. Die `Bridge` erkennt ESX/QB automatisch, nutzt sie aber nur für Admin-Permissions und Spielernamen. Ein Replay-System braucht kein Framework — und ein Standalone-Produkt verdoppelt den Markt.

### 17.3 Bridge — auf dem `d-dl`-Muster aufbauen

Das ist die erklärte Architekturrichtung. D-RPS baut darauf auf und geht einen Schritt weiter:

```lua
-- Config.Framework = 'auto' | 'esx' | 'qb' | 'standalone'
-- Auto-Detect via GetResourceState(...):find('start')

Bridge.GetPlayerName(src)    -- ESX: xPlayer.getName() / QB: charinfo / SA: GetPlayerName
Bridge.IsAdmin(src)          -- ESX: group / QB: permission / SA: IsPlayerAceAllowed
Bridge.GetIdentifier(src)    -- license: bevorzugt (§18)
```

⚠️ **Hinweis:** `d-dl/bridge/*.lua` existiert auf der Platte, ist aber **noch nicht in `d-dl/fxmanifest.lua` gelistet** — der Live-Code ruft weiterhin `ESX.` direkt. D-RPS ist die Gelegenheit, das Muster sauber zu Ende zu bauen und dann nach `d-dl` zurückzuportieren.

### 17.4 Öffentliche Exports

Das ist gleichzeitig Feature und Verkaufsargument:

```lua
-- Animation melden (für Fremd-Resources)
exports['d-rps']:RegisterAnim(dict, name, flags)
exports['d-rps']:UnregisterAnim(dict, name)
exports['d-rps']:PlayAnim(ped, dict, name, blendIn, blendOut, dur, flags)  -- Drop-in

-- Falsch-Positive vermeiden
exports['d-rps']:SuppressCameraChecks(playerId, durationMs, reason)

-- Eigene Events in die Timeline schreiben
exports['d-rps']:LogEvent(playerId, category, label, data)

-- Programmatischer Incident-Export
exports['d-rps']:ExportIncident(playerId, tStart, tEnd)  -- → incidentId
```

`LogEvent` ist unterschätzt: Damit kann `md_wunden` seine Wunden, `d-dl` seine Labor-Transaktionen und jedes beliebige Resource seine Ereignisse in die Replay-Timeline schreiben. **Das macht D-RPS zur Plattform statt zum Einzelscript** — und erzeugt einen Ökosystem-Effekt um deine eigenen Produkte.

### 17.5 Config-Stil (bestehende Konvention)

Flach, deutscher Kommentar über **jeder** Einstellung, Produktionshinweise laut markiert:

```lua
-- Aufzeichnungsdauer im RAM in Minuten.
-- Speicherbedarf ≈ Spieler × 0,35 KB/s × Minuten × 60
-- Beispiel: 64 Spieler × 30 min ≈ 40 MB. Bei 128 Spielern verdoppelt sich das.
Config.BufferMinutes = 30

-- Client-Reporter: liefert Animationen, Kleidung und Kamera-Pitch.
-- Ohne ihn läuft D-RPS weiter, aber Replays zeigen nur Standard-Peds
-- ohne Animationen und die Widerspruchsprüfung entfällt.
-- Kosten: < 0,1 ms Client-Tick, ~0,15 KB/s Upload pro Spieler.
Config.Reporter = true

-- Web-Portal über SetHttpHandler.
-- >>> ACHTUNG: oeffnet einen HTTP-Endpunkt auf der Server-IP.
-- >>> NUR aktivieren, wenn ein Reverse-Proxy mit TLS davorsteht.
Config.WebPortal = false

-- Debug-Modus: Test-Commands (/rps_dump, /rps_bench, /rps_sim)
-- MUSS auf false stehen auf einem Live-Server
Config.Debug = false
```

---

<a name="18-dsgvo"></a>
## 18. DSGVO & Rechtliches

Für ein Produkt, das primär an deutsche und EU-Server verkauft wird, ist das **kein Anhang, sondern ein Feature.**

### 18.1 Was wir verarbeiten

Verhaltensdaten (Position, Aktionen) verknüpft mit Identifikatoren (`license:`, `steam:`, `discord:`) = **personenbezogene Daten** nach Art. 4 DSGVO. Kein Grenzfall.

### 18.2 Warum unsere Architektur hilft

| Prinzip | Wie D-RPS es erfüllt |
|---|---|
| **Datenminimierung** (Art. 5) | Kein Video, kein Bild, kein Ton — nur Koordinaten. Ein Replay enthält **keine biometrischen Daten und keinen Chat** (Chat-Text nur optional, Default aus, §13.2.7). |
| **Speicherbegrenzung** (Art. 5) | ⚠️ **Geändert durch die 24h-Archiv-Anforderung (§8.4).** Der „weg beim Neustart"-Automatismus gilt nur noch für den RAM-Ringpuffer; das Disk-Archiv **überlebt** den Neustart. → **Konfigurierbare Retention ist Pflicht:** Tagesarchive automatisch nach `Config.RetentionDays` (Default 3–7) löschen. Ohne diese Auto-Löschung ist das Produkt nicht DSGVO-konform auslieferbar. |
| **Zweckbindung** (Art. 5) | Nur Admin-Review. Vollarchiv gegen Retention; Incident-Exporte dauerhaft. |
| **Recht auf Löschung** (Art. 17) | RAM: automatisch. Archiv: Retention-Auto-Delete + manuelle Lösch-/Sperrfunktion pro Identifier. Incidents: Export-Löschfunktion nötig. |
| **Auskunft** (Art. 15) | Export der eigenen Daten via Identifier über den Index. |

> **Ehrliche Einordnung des Trade-offs:** Das 24h-Vollarchiv **schwächt** den ursprünglich stärksten DSGVO-Punkt („flüchtig, weg beim Neustart"). Ein persistentes Bewegungsprotokoll aller Spieler über Tage ist schwerer zu rechtfertigen als ein selbstlöschender RAM-Puffer. Es bleibt **deutlich** harmloser als Video (kein Bild/Chat/Audio, kein Fremd-CDN), aber das Argument verschiebt sich von „flüchtig" zu **„strukturiert, minimiert, mit klarer Löschfrist"**. Retention + Pseudonymisierung (§18.3) sind damit keine Kür, sondern Auslieferungsbedingung.

**Weiterhin ein echter Vorteil gegenüber Video.** Ein 720p-Video vom Bildschirm eines Spielers enthält seinen Chat, seine Discord-Overlays, potenziell seinen Klarnamen, seine Nachrichten. Auf einem CDN eines Drittanbieters. **Ein FiveManage-Account ist eine Auftragsverarbeitung nach Art. 28** und braucht einen AV-Vertrag. Unsere Daten verlassen den Server nie.

Das gehört **groß auf die Produktseite**, nicht ins Kleingedruckte. Für deutsche Server-Betreiber ist das ein Kaufargument.

### 18.3 Was wir dem Käufer mitgeben

- **Muster-Datenschutzhinweis** zum Einbinden in seine Server-Regeln
- **Config-Schalter** für Identifier-Pseudonymisierung (Hash statt `license:`), default **an**
- **Anonymisierungs-Modus** fürs Review (Overwatch-Präzedenz, §13.7): Namen als „Spieler A/B/C"
- **Retention-Config** mit Doku
- Klare Doku, dass **Konfiguration = Verantwortung des Betreibers**

⚠️ **Kein Rechtsrat von mir.** Für ein kommerzielles Produkt mit DSGVO-Bezug lohnt eine anwaltliche Kurzprüfung der Produktseite und der mitgelieferten Muster. Ich kann die Technik so bauen, dass sie datensparsam ist — die rechtliche Bewertung ist nicht meine.

---

<a name="19-tebex"></a>
## 19. Tebex, Escrow, Pricing

### 19.1 Plattform-Fakten

- **Tebex ist Pflicht** — *„exclusive monetization partner"*. Andere Zahlungsanbieter verletzen die Platform License Agreement.
- Der Cfx Marketplace (Jan 2026) ist eine **zusätzliche Storefront, ebenfalls von Tebex abgewickelt** — keine Alternative.
- Escrow **unterstützt Abos nativ**; bei Ablauf startet das Asset nicht mehr.

### 19.2 Preisempfehlung

Das Killcam-Band ist 4–50 €. Das Anticheat-Band ist 12–50 €/Monat. **D-RPS liegt technisch dazwischen und funktional darüber.**

| Variante | Preis | Begründung |
|---|---|---|
| **D-RPS Escrow** | **24,99 €** | Über thug (17,99 €), weil deutlich mehr Funktion und **keine Folgekosten**. Der ehrliche Pitch: „Teurer im Kauf, günstiger im Betrieb — thug kostet dich ab Tag 1 ein FiveManage-Abo." |
| **D-RPS Open Source** | **69,99 €** | 2,8× — im Korridor der Kategorie (2,0–3,0×). |

**Kein Abo.** Das Band ist mit Abos besetzt (FiniAC, Raven, Aegissec) und wir haben keine laufenden Kosten, die eines rechtfertigen. **„Einmal kaufen, keine Folgekosten, keine CDN-Rechnung"** ist gegen thugs versteckte FiveManage-Kette die stärkste Position, die man haben kann.

### 19.3 Der Pitch in drei Zeilen

> **thug nimmt 15 Sekunden 720p-Video auf und schickt sie auf ein fremdes CDN, das du monatlich bezahlst.**
> **D-RPS zeichnet 30 Minuten kompletten Serverzustand auf, in 40 MB RAM — mit Freikamera, Zeitlupe und automatischer RDM/VDM-Erkennung.**
> **Keine Folgekosten. Keine Fremdserver. Deine Daten bleiben bei dir.**

Und der Satz, der den RP-Server-Betreiber wirklich trifft:

> **Schluss mit „Aussage gegen Aussage". Schau es dir einfach an.**

### 19.4 Was auf die Produktseite gehört

**Ehrlich, weil es sonst als Refund zurückkommt:**

- ✅ **Erkennt automatisch:** RDM, VDM, Combat-Logging, NLR-Verstöße, Spawn-Kills, Safezone-Verstöße — plus Teleport, Speedhack, Godmode, Entity-/Waffen-Spawn, Explosion-Spam
- ✅ **Macht überprüfbar:** alles andere. Fail-RP, Powergaming, strittige Situationen — in 30 Sekunden aus jedem Winkel, statt drei Beteiligte zu befragen und drei Versionen zu bekommen.
- ⚠️ **Fängt teilweise:** Silent Aim, Aimbot (Widerspruchsprüfung — fängt Standard-Cheats, nicht die getunten)
- ❌ **Kann es nicht:** Metagaming (Discord ist außerhalb), ESP (es existieren keine Daten), 100 % originalgetreue Optik, Fremd-Anims ohne Integration, exakte Fahrzeug-Deformation, exakte Ragdoll-Pose
- 📊 **Gemessene Performance-Zahlen** aus dem Profiler-Lauf, nicht „extremely low resmon"

Die ❌-Liste ist **kein Verkaufshindernis, sondern Vertrauensaufbau.** Wenn thug „Most Advanced" behauptet und wir Messwerte plus eine ehrliche Grenzliste liefern, gewinnen wir den Käufer, der weiß, was er tut — und das ist der Käufer, der keine Support-Tickets schreibt.

---

<a name="20-roadmap"></a>
## 20. Roadmap

### M0 — Verifikation (§22) · ~0,5 Tage
Die fünf offenen Punkte messen, bevor irgendwas gebaut wird.

### M1 — Recorder + Ringpuffer · ~2 Tage
Server-Sampling, Binärformat, Ring, `/rps_dump`, `/rps_bench`. **Erfolgskriterium: < 1,5 ms Server-Tick bei 64 simulierten Spielern, gemessen mit dem Profiler.**

### M2 — Event-Collector + Interaktions-Graph + Detection v1 · ~3 Tage
Alle Events; Interaktions-Graph (§13.2.1); **RDM, VDM, Combat-Log, NLR, Spawn-Kill** (die belastbaren, server-autoritativen Klassen); dazu Teleport/Speed/Godmode/Spawn; Incident-Erzeugung; Discord-Webhook.

**Ab hier liefert das Produkt seinen Kernnutzen** — noch ganz ohne 3D. Das ist der wichtigste Meilenstein im Plan.

### M3 — Reporter · ~1,5 Tage
Client-Flags, Kamera, Appearance, Anim-Instrumentierung, Exports. **Erfolgskriterium: < 0,1 ms Client-Tick.**

### M4 — Playback-Engine · ~4 Tage
Bucket-Bühne, Klon-Peds, Interpolation, Lokomotions-Hybrid, beide Modi, Freikamera. **Der größte und riskanteste Brocken.** §12 ist hier die Referenz.

### M5 — Ingame-NUI · ~2,5 Tage
React/Vite/Tailwind, Timeline, Scrubber, Spielerliste, Incident-Panel, Vertrauens-Kennzeichnung.

### M6 — Detection v2: Widerspruchsprüfung + LOS · ~2 Tage
§13.4 und §13.5. Der Cheat-Bonus obendrauf. Braucht M3 und M4.

**Bewusst spät.** Für den Hauptzweck nicht kritisch — wenn hier etwas hakt, steht das Produkt trotzdem.

### M7 — Web-Portal · ~2 Tage
`SetHttpHandler`, 2D-Karte, Auth, Range-Streaming.

### M8 — Produktisierung · ~2 Tage
Locales de/en, README, Installationsanleitung, Escrow-Build, Profiler-Report, Tebex-Seite, Muster-Datenschutzhinweis.

**Summe: ~18–19 Tage** für v1.0. Realistisch bei fokussierter Arbeit; die Unsicherheit sitzt fast vollständig in M4.

### Empfohlener Schnitt für ein frühes Release

**M1 + M2 + M7 = „D-RPS Lite"** (~6 Tage): Event-Log, Detection und 2D-Web-Timeline. Verkaufbar bei ~14,99 €, validiert den Markt, finanziert M3–M6 und liefert den Kunden ab Tag 1 echte Bans. Das 3D-Replay wird dann das große v2.0-Update — mit Upgrade-Pfad für Bestandskunden.

Das ist auch risikoärmer: Wenn M4 sich als härter erweist als geplant (und Lokomotion **wird** fummelig), steht das Produkt trotzdem.

---

<a name="21-offen"></a>
## 21. Offene Entscheidungen & Risiken

### 21.1 Entscheidungen, die du treffen solltest

| # | Frage | Status |
|---|---|---|
| 1 | **Primärer Zweck?** | ✅ **ENTSCHIEDEN (2026-07-16): Regelbrüche nachvollziehen.** Nicht Killcam, nicht primär Anti-Cheat. §13.2 ist entsprechend der Kern; §13.4/§13.5 sind Bonus. Killcam wäre auf derselben Basis ein günstiges Zusatzfeature — aber es steuert die Architektur nicht. |
| 2 | **„Lite" zuerst oder direkt v1.0?** | ✅ **ENTSCHIEDEN: direkt komplett.** Damit bleibt M4 das Hauptrisiko → **Gegenmaßnahme: M4-Lokomotions-Prototyp vorziehen** (siehe §21.2), bevor M2/M3 gebaut werden. Ein Tag Prototyp entschärft vier Tage Risiko. |
| 3 | **Standalone oder ESX-only?** | **Standalone mit Bridge.** Verdoppelt den Markt, kostet ~einen halben Tag. |
| 4 | **Escrow, Open Source oder beides?** | **Beides**, 24,99 / 69,99 €. Kategorie-Standard. |
| 5 | **Buffer-Default?** | **30 Minuten.** 40 MB bei 64 Spielern ist unauffällig. |
| 6 | **Chat-Text aufzeichnen?** | Empfehlung: **Default aus** (§13.2.7). Der Zeitpunkt reicht für die Heuristik; der Inhalt ist das personenbezogenste Datum im System. |
| 7 | **Welches Voice-Resource?** | Offen — bestimmt den Bridge-Adapter für das Sprech-Signal (§13.2.7). pma-voice / mumble-voip / saltychat haben unterschiedliche APIs. |

### 21.2 Risiken

| Risiko | Schwere | Minderung |
|---|---|---|
| **M4-Lokomotion sieht schlecht aus** | **hoch** | Der Hybrid (§12.2) ist der dokumentierte Konsens echter Implementierungen, aber „gut genug" ist Geschmackssache. **Früher Prototyp mit einem Spieler, bevor M4 voll gebaut wird.** Lite-Schnitt entschärft das. |
| **Ragdoll nicht reproduzierbar** | mittel | Euphoria-Physik ist nicht deterministisch und nicht schreibbar. **Als Approximation kennzeichnen** (§11.3). Nicht lösbar, nur ehrlich handhabbar. |
| **Fremd-Anims fehlen** | mittel | Export bewerben, Allowlist, offen dokumentieren (§12.5). |
| **`explosionEvent` bricht bei Build-Wechsel** | mittel | Build pinnen, Parser versionieren, Format-Version im Chunk-Header. |
| **Cheater fälscht Reporter überzeugend** | mittel | Nicht lösbar (§13.1). Reporter ≠ Evidence. Ehrlich kommunizieren. |
| **`CancelEvent`-Bug ([#2395](https://github.com/citizenfx/fivem/issues/2395))** | niedrig | **Wir cancelen nie.** Trifft uns nicht — und ist ein Verkaufsargument. |
| **Escrow-Leak** | niedrig | Unvermeidbar (§16.3). Einpreisen. |
| **`string.pack` fehlt wider Erwarten** | niedrig | Fallback auf `msgpack` (C, global verfügbar) — größer, aber funktional. **M0 klärt das.** |
| **DSGVO-Abmahnung eines Kunden** | niedrig | Muster mitliefern, Verantwortung dokumentieren, anwaltliche Kurzprüfung. |

### 21.3 Was ich bewusst weggelassen habe

- **Video-Fallback.** Technisch möglich (`screencapture`), aber es importiert genau die Kostenstruktur und Fragilität, gegen die wir positionieren.
- **ML-Detection.** VACnets Erfolg lag am **Datensatz und am Review-Modell**, nicht am Netz. Ohne menschlich gelabelte Verurteilungen ist ein Modell wertlos. **Später möglich** — die Incidents mit Admin-Verdikt *sind* der Trainingsdatensatz. Das ist ein v3-Thema und ein echter Burggraben, wenn die Datenbasis erst existiert.
- **Automatische Bans.** Nie. §13.7.

---

<a name="22-verifikation"></a>
## 22. Verifikationsliste vor Code-Start

> ### ✅ Sondenlauf 2026-07-19 (Testserver `fivem-dev-01`, Build 3258, ESX Legacy, pma-voice, OneSync on)
>
> Die Wegwerf-Sonde `_probe/` hat die offenen Annahmen gemessen. Ergebnisse:
>
> | Punkt | Ergebnis |
> |---|---|
> | **OneSync** | ✅ `on` (txAdmin setzt es per `+set onesync on`, nicht in der cfg) — Fundament steht |
> | **`string.pack`** | ✅ funktioniert, Roundtrip korrekt (13 B für das Delta-Format — die „14" im Entwurf war ein Rechenfehler) |
> | **Server-Getter** | ✅ 8/8 (`GetEntityCoords/Rotation/Heading/Health/Velocity`, `GetPedArmour`, `GetEntityModel`, `GetVehiclePedIsIn`), liefern echte Werte |
> | **Kamera serverseitig** | ✅ bestätigt §3.4: `y=0.0000` → **Pitch wird verworfen**, nur Yaw. Für Pitch braucht es den Reporter. |
> | **`SetEntityHealth`** | ✅ fehlt serverseitig (bestätigt §3.1) |
> | **Recorder-Kosten** | ✅ **0,064 ms/Tick @48 Spieler** mit Packing — 23× unter dem 1,5-ms-Ziel. Ped-Cache spart 48 %. |
> | **Payload-Limit** | ✅ **≥ 512 KB** ohne Bruch (die „32 KB"-Forum-Vermutung war zu pessimistisch) — 14-KB-Segmente absolut sicher |
> | **`GET_PED_MOVEMENT_CLIPSET`** | ✅ gibt den **Hash** zurück (2. Anlauf) → direkt aufzeichenbar, kein Wrapper nötig |
> | **Appearance-Capture** | ✅ Components/Props/FaceFeatures 0–19/HeadOverlay alle lesbar, inkl. der CFX-Natives |
> | **`Wait(50)`-Timing** | ⚠️ **real ~64 ms, variabel** (nicht 50 ms) → **Format auf Zeitstempel umgestellt**, siehe §5.3 |
> | **HeadBlend-Readback** | ⚠️ `DataView` clientseitig nicht verfügbar → Fallback §7.3 (Appearance beim Setzen cachen) |
> | **`FORCE_PED_MOTION_STATE`** | ⚠️ gibt `false` für alle `updateState` → Optik im M4-Prototyp visuell beurteilen |
> | **VDM-Lenkwinkel serverseitig** | ❓ **noch offen** — Sondentest fehlerhaft (`InvokeNative` ohne `ResultAsFloat`-Hint → `false`; Auto stand zudem still). Beim M2-Bau mit korrektem Hint + fahrend verifizieren. |
> | **Client-Reporter-Kosten (C4)** | ❓ nicht sauber messbar in der Sonde (`GetGameTimer` steht im synchronen Loop still). Gehört an den echten M3-Reporter via resmon (§15.3). |
> | **Disk-Persistenz-Schreibpfad** | ✅ **GELÖST in M1 (2026-07-25):** `SaveResourceFile` schreibt nur in *existierende* Ordner, legt keine an. `os.execute` ist eine **Attrappe** (Typ `function`, aber wirkungslos — `mkdir` ohne Effekt). `io.open('ab')` voll funktionsfähig (write+append, abs. Pfad via `GetResourcePath`). `os.remove` verfügbar (Retention geht). **Architektur:** eine Append-Datei pro Spieler pro Tag im mitgelieferten `archive/`-Ordner, längen-präfixierte Chunks — keine Unterordner. |
>
> **Fazit:** Alle kritischen Annahmen bestätigt, das Fundament trägt. Zwei Messfehler meinerseits (`os.clock` = CPU-Zeit, `GetGameTimer` frame-konstant) betrafen nur Timing, nicht die Fähigkeiten. Zwei Punkte bleiben für M1/M2 offen (VDM-Steering, Disk-Schreibpfad).

Ursprüngliche Liste (Stand vor dem Sondenlauf):

| # | Frage | Test | Fallback wenn negativ |
|---|---|---|---|
| 1 | **Ist `string.pack` in CfxLua verfügbar?** Ableitungskette (CfxLua = LuaGLM = Lua 5.4.4, LuaGLM-README nennt `string.pack` als erhalten) ist stark, aber **kein Cfx-Doc sagt es explizit.** | `print(#string.pack('<i4', 1))` → erwartet `4` | `msgpack` (C, global). Größer, funktioniert. **Format-Design ändert sich nicht.** |
| 2 | **Was gibt `GET_PED_MOVEMENT_CLIPSET` zurück?** Hash oder interner Index? Was bei Default? DB-Beschreibung ist leer. | `SetPedMovementClipset` mit bekanntem Clipset, dann lesen und mit `GetHashKey` vergleichen | Clipset über den `SetPedMovementClipset`-Wrapper instrumentieren (wie Anims, §12.3) |
| 3 | **Wie groß ist `kMaxPacketSize` wirklich?** Der Code prüft dagegen, der Wert steckt in einem Net-Header. Die kursierenden „32 kB / 128 kB" sind **Forum-Vermutung.** | Segmente wachsender Größe senden, Bruchpunkt messen | Segmente kleiner schneiden; Latent für Bulk |
| 4 | **Semantik von `updateState` bei `FORCE_PED_MOTION_STATE`** | Werte 0–3 durchprobieren, Ergebnis beobachten | Empirisch bestes Ergebnis hartkodieren |
| 5 | **`GET_PED_HEAD_BLEND_DATA` Buffer-Stride in Lua** | Struct lesen, gegen bekannte Werte prüfen (4 B Padding nach jedem Feld = 8 B Stride) | Appearance über den bestehenden Charakter-Editor des Kunden beziehen |

Zusätzlich empfohlen: **`Wait(50)`-Genauigkeit messen.** Die Ableitung sagt exakt ein Tick. Ein 60-s-Lauf mit `os.clock()`-Drift-Messung kostet nichts und validiert die Kernannahme des ganzen Formats.

---

## Anhang A — Quellen

**Engine-Quellcode** (die belastbarsten Belege — Doku ist an vielen Stellen unvollständig oder veraltet):
- [`ServerGameState.cpp`](https://github.com/citizenfx/fivem/blob/master/code/components/citizen-server-impl/src/state/ServerGameState.cpp) — Event-Payloads (:4927), Routing-Switch (:7631), Cancel-Gate (:7998), Tick-Drosselung (:873)
- [`GameServer.cpp`](https://github.com/citizenfx/fivem/blob/master/code/components/citizen-server-impl/src/GameServer.cpp) — Tick-Raten (:204/:333/:449), Hitch-Warnung (:222)
- [`ResourceMonitor.cpp`](https://github.com/citizenfx/fivem/blob/master/code/components/citizen-devtools/src/ResourceMonitor.cpp) — 6-ms-Schwelle, 64-Tick-Mittel, Farbrampe
- [`rpc_spec_natives.lua`](https://github.com/citizenfx/fivem/blob/master/ext/natives/rpc_spec_natives.lua) — welche Natives RPC sind
- [`EventReassemblyComponent.cpp`](https://github.com/citizenfx/fivem/blob/master/code/components/citizen-resources-core/src/EventReassemblyComponent.cpp) — Latent-Event-bps ist **per-Target**
- [`StateBagPacketHandler.cpp`](https://github.com/citizenfx/fivem/blob/master/code/components/citizen-server-impl/src/packethandlers/StateBagPacketHandler.cpp) — Rate-Limits

**Native-Datenbanken** (autoritativ; docs.fivem.net und cfxnatives.dev sind SPAs und maschinell schlecht lesbar):
- [`natives.json`](https://runtime.fivem.net/doc/natives.json) — Base-GTA-V-Natives
- [`natives_cfx.json`](https://runtime.fivem.net/doc/natives_cfx.json) — CFX-Additions
- [`natives_server.d.ts`](https://unpkg.com/@citizenfx/server/natives_server.d.ts) — was serverseitig aufrufbar ist
- [alloc8or.re — eTaskTypeIndex](https://alloc8or.re/gta5/doc/enums/eTaskTypeIndex.txt) — 437 Task-Indizes

**Doku:**
[OneSync](https://docs.fivem.net/docs/scripting-reference/onesync/) · [State Bags](https://docs.fivem.net/docs/scripting-manual/networking/state-bags/) · [Server Events](https://docs.fivem.net/docs/scripting-reference/events/server-events/) · [Asset Escrow](https://docs.fivem.net/docs/server-manual/asset-escrow/) · [Profiler](https://docs.fivem.net/docs/scripting-manual/debugging/using-profiler/) · [Lua-Runtime](https://docs.fivem.net/docs/scripting-manual/runtimes/lua/) · [Lua-5.3-Entfernung](https://forum.cfx.re/t/removal-of-lua-5-3-support/5335232)

**Wettbewerb:**
[thug-replay-system Forum](https://forum.cfx.re/t/most-advanced-automatic-kill-pov-replay-system-thug-replay-system/5394623) · `thug.gitbook.io/documentation` · [FiveManage Pricing](https://fivemanage.com/pricing) · [itschip/screencapture](https://github.com/itschip/screencapture) · [lucid-killcam](https://github.com/LucidB1/lucid-killcam) · [Vehicle-Replay-Artikel](http://www.patrikpapso.com/posts/fivem-recording-and-playing-a-car-replay/)

**Forschung & Präzedenz:**
[Witschel & Wressnegger, „Aim Low, Shoot High" (EuroSec '20)](https://arxiv.org/abs/2004.12183) · [McDonald, „Robocalypse Now" (GDC 2018, VACnet)](https://www.gdcvault.com/play/1024994/Robocalypse-Now-Using-Deep-Learning) · [ReplayStudio (.mcpr-Format)](https://github.com/ReplayMod/ReplayStudio) · [ServerReplay](https://github.com/senseiwells/ServerReplay)

**Bekannte Bugs:**
[#2395 CancelEvent kaputt](https://github.com/citizenfx/fivem/issues/2395) · [#3827 Hash-„Mismatch" (kein Bug)](https://github.com/citizenfx/fivem/issues/3827) · [weaponDamageEvent auf 2060](https://forum.cfx.re/t/onesync-server-weapondamageevent-does-not-behave-correctly-on-build-2060/1717489) · [#1360 Latent-Broadcast-Hitches](https://github.com/citizenfx/fivem/issues/1360) · [#1366 Rockstar Editor vs. Escrow-Assets](https://github.com/citizenfx/fivem/issues/1366)

---

## Anhang B — Glossar der Vertrauensstufen

Durchgängig in Code, UI und Doku zu verwenden:

| Stufe | Bedeutung | Beispiel |
|---|---|---|
| 🛡 **AUTHORITATIVE** | Server hat es unabhängig beobachtet | Position, Health, Fahrzeug |
| ⚠️ **CLAIM** | Client hat es behauptet | `weaponDamageEvent`, Kamera, Anims |
| 🔍 **DERIVED** | Aus mehreren Quellen berechnet | Widerspruchs-Score, LOS-Ergebnis |
| ❓ **APPROXIMATED** | Rekonstruiert, nicht aufgezeichnet | Ragdoll-Pose, Fahrzeug-Deformation |

**Jedes Datum in der UI trägt sein Siegel. Ohne Ausnahme.**
