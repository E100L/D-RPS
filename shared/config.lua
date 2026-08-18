--[[ D-RPS — Dollar Replay System / shared/config.lua
     Zentrale Kaeufer-Konfiguration (liegt im escrow_ignore).
     Konvention: flache Config.X-Zuweisungen, Produktionshinweise mit >>>. ]]

Config = {}

-- ── Allgemein ──────────────────────────────────────────────────────────────

-- Debug-Modus: gespraechigere Konsole, schaltet Diagnose-Commands frei
-- (/rps_stats, /rps_verify, /rps_selftest). Vergibt KEINE Rechte — die Commands
-- verlangen zusaetzlich Config.AdminAce. Live-Server: aus lassen.
Config.Debug = false

-- Sprache ('de' oder 'en'). Fallback ist immer 'de'.
Config.Locale = 'de'

-- Rueckmeldungen ueber die native GTA-Benachrichtigung unten links.
Config.Notifications = true

-- Melder benachrichtigen, wenn sich der Status seiner Meldung aendert.
Config.NotifyReporter = true

-- Team (Config.AdminAce) bei neuer Meldung benachrichtigen.
Config.NotifyAdmins = true

-- ACE-Berechtigung fuer Team-Funktionen (Replay, Meldungen bearbeiten).
-- >>> In server.cfg: add_ace group.admin d-rps.admin allow
Config.AdminAce = 'd-rps.admin'

-- Alternative zur ACE-Vergabe: Identifier, die immer als Team gelten (Server
-- ohne ACE-Gruppen). Vollstaendige Identifier wie von GetPlayerIdentifiers:
--   Config.AdminIdentifiers = { 'license:1a2b...', 'discord:1234...' }
-- >>> Leer lassen, wenn die Berechtigung ueber ACE laeuft (ohne Neustart aenderbar).
Config.AdminIdentifiers = {}

-- ── Recorder ───────────────────────────────────────────────────────────────

-- Ziel-Abstand zwischen zwei Samples in ms (nur ZIEL — Scheduler ist ungenau,
-- der Recorder rechnet mit echten Zeitstempeln). 50 ≈ 15-20 Hz real.
Config.SampleIntervalMs = 50

-- Sekunden ohne nennenswerte Bewegung, ab denen ein Spieler auf die reduzierte
-- Rate gedrosselt wird. Spart Speicher auf RP-Servern. 0 = Drosselung aus.
Config.IdleAfterSeconds = 3

-- Reduziertes Intervall fuer stehende Spieler (ms). 200 = 5 Hz.
Config.SampleIntervalIdleMs = 200

-- Bewegungsschwelle in Metern, unter der ein Spieler als "steht" gilt.
Config.IdleMoveThreshold = 0.15

-- ── RAM-Ringpuffer ─────────────────────────────────────────────────────────

-- Minuten der juengsten Aufzeichnung im RAM (schnelles Fenster fuer Live-
-- Detection, NICHT das Gesamtarchiv). 48 Spieler × 5 min ≈ 4 MB.
Config.RamBufferMinutes = 5

-- Minuten Vorgeschichte je Replay. Alles ueber RamBufferMinutes kommt aus dem
-- Disk-Archiv.
-- >>> Ab ~30 min bei vielen Spielern wird die Uebertragung spuerbar; dann besser
-- >>> gezielt ueber eine Meldung einsteigen (/ticket_open).
Config.ReplayWindowMinutes = 20

-- ── Disk-Archiv (24h-Vollaufzeichnung) ─────────────────────────────────────

-- Kontinuierliches Streamen auf Platte. Ohne das nur RAM-Ring, kein Tagesarchiv.
Config.DiskArchive = true

-- Obergrenze fuer die Chunklaenge in Sekunden.
-- >>> In der Praxis bestimmt Config.SegmentSeconds die Chunklaenge (Chunk gehoert
-- >>> zu genau EINEM Segment). Dieser Wert greift nur als Sicherheitsnetz.
Config.DiskChunkSeconds = 60

-- Unterordner im Resource-Verzeichnis. Struktur:
-- <ArchivePath>/<YYYY-MM-DD>/<HHMM>_<playerHash>.chunk
Config.ArchivePath = 'archive'

-- >>> DSGVO-PFLICHT: Aufbewahrungsdauer der Tagesarchive in Tagen; aeltere werden
-- >>> geloescht. 0 = NIE loeschen (nur mit eigener Loeschstrategie).
-- Geflaggte Incidents sind ausgenommen und bleiben erhalten (Ban-Appeal-Archiv).
Config.RetentionDays = 7

-- Identifier vor dem Schreiben pseudonymisieren (Hash statt license:).
-- >>> Empfohlen an. Klarname bleibt nur im separaten Session-Index.
Config.PseudonymizeIdentifiers = true

-- ── Segment-Streaming ──────────────────────────────────────────────────────
-- Aufzeichnung in festes Zeitraster zerlegt. Client bekommt beim Oeffnen zuerst
-- nur ein Verzeichnis (wer wann online), Bewegungsdaten dann segmentweise wie ein
-- Videoplayer. Nur so laesst sich ein 24h-Archiv ohne Vollladung durchsuchen.

-- Breite eines Segments in Sekunden; bestimmt zugleich die Chunklaenge. Kleiner
-- = feineres Nachladen, aber mehr Dateizugriffe/Keyframes. Sinnvoll: 15 bis 60.
Config.SegmentSeconds = 30

-- Vorgeschichte des Verzeichnisses in Minuten. Kostet fast nichts (je Spieler
-- und Segment ein Zeichen). 1440 = volle 24 Stunden.
Config.SegmentWindowMinutes = 120

-- Groesse einer einzelnen Antwort in Byte. Netz-Ereignis traegt gemessen min.
-- 512 KB; die Haelfte laesst Luft fuer den Rahmen.
Config.SegmentMaxBytes = 262144

-- Segmente je Sekunde und Team-Mitglied. Bremst Anfragefluten ohne einen Sprung
-- auf der Zeitleiste auszubremsen.
Config.SegmentRatePerSec = 8

-- Hoechstzahl Spieler je Segment (nach Naehe zum verfolgten Spieler). Greift der
-- Deckel, zeigt die Oberflaeche es an — nie stillschweigend weglassen.
Config.SegmentMaxActors = 12

-- Hoechstzahl gleichzeitig angeforderter Segmente.
Config.SegmentMaxInFlight = 3

-- Sekunden Vorausladen, in Laufrichtung.
Config.PrefetchSeconds = 120

-- Sekunden, die der Client im Speicher haelt; Rest wird verworfen und bei Bedarf
-- neu geholt.
Config.ClientCacheSeconds = 300

-- Zeitbudget je Bild fuers Dekodieren nachgeladener Segmente (ms). Hoeher =
-- schneller geladen, aber sichtbares Ruckeln.
Config.DecodeBudgetMs = 1.5

-- Entprellung beim Ziehen ueber die Zeitleiste (ms): so lange muss der Abspielkopf
-- ruhen, bevor nachgeladen wird — sonst loest jedes Pixel eine Anfrage aus.
Config.SegmentSeekSettleMs = 120

-- Luecke zwischen zwei Zustaenden (Sekunden), ab der ein Logout angenommen wird.
-- >>> Ohne diese Unterscheidung wuerde das Replay ueber einen Logout hinweg
-- >>> interpolieren — der Spieler gliete quer ueber die Karte wie bei Teleport.
Config.SegmentGapSeconds = 5.0

-- ── Interaktions-Graph (Basis der Regelbruch-Erkennung, §13.2.1) ───────────

-- Radius (m), in dem zwei Spieler als "in Naehe" gelten. 50 = typischer RP-Raum.
Config.ProximityMeters = 50.0

-- Reichweite (m), in der eine Chat-/Sprach-Nachricht als "gerichtet" zaehlt.
-- Etwas groesser als Proximity (man schreit/funkt auch aus Distanz).
Config.CommsRangeMeters = 60.0

-- Minuten, die ein Interaktions-Eintrag ohne neuen Kontakt behalten wird
-- (Gedaechtnis fuer die RDM-Vorgeschichte).
Config.InteractionWindowMinutes = 10

-- Update-Takt des Graphen (ms). 500 = 2 Hz, haelt die O(n²)-Paarpruefung billig.
Config.InteractionUpdateMs = 500

-- Chat-TEXT mitschreiben? Fuer die Heuristik reicht der Zeitpunkt; der Inhalt ist
-- das personenbezogenste Datum (§18). >>> Default aus, nur bewusst aktivieren.
Config.RecordChatText = false

-- ── Meldungen (/ticket) ────────────────────────────────────────────────────
-- Einstieg in den Arbeitsablauf: Spieler meldet, Admin springt im Replay zum
-- Zeitpunkt.

-- Mindest- und Hoechstlaenge der Beschreibung.
Config.TicketMinLength = 8
Config.TicketMaxLength = 240

-- Wartezeit (Sekunden), bis derselbe Spieler erneut melden darf.
Config.TicketCooldownSeconds = 30

-- Umkreis (m), in dem beim Melden festgehalten wird, wer dabei war.
Config.TicketNearbyRadius = 60.0

-- ── Automatische Erkennung (optional, standardmaessig AUS) ────────────────
-- Erkennt Regelbrueche selbsttaetig. Erzeugt je nach Serverregeln Falsch-
-- Positive und muss eingestellt werden — Standard ist der Einstieg per Meldung.
-- >>> Zum Aktivieren einzelne Eintraege auf true setzen.
Config.Detect = {
    CombatLog = false,   -- Disconnect kurz nach Kampf
    RDM       = false,   -- Toetung ohne vorherigen Kontakt
    VDM       = false,   -- Anfahren mit Fahrzeug
    SpawnKill = false,   -- Toetung kurz nach Spawn/Join
    NLR       = false,   -- Rueckkehr an den Todesort
}

-- Ab welcher Konfidenz (0..1) ein Incident erzeugt wird.
Config.DetectMinConfidence = 0.5

-- Combat-Log: Sekunden nach letztem Schaden (gegeben ODER genommen), in denen
-- ein Disconnect als Combat-Logging gilt.
Config.CombatLogSeconds = 60

-- RDM: Rueckblick-Fenster (Minuten) fuer "gab es Kontakt?". Sollte <= dem
-- Interaktions-Fenster sein.
Config.RdmLookbackMinutes = 5

-- RDM: Mindestdistanz (m) Schuetze→Opfer fuer einen kontaktlosen Kill. Darunter
-- ist es Nahkampf/Gerangel — zu viele Fehlalarme.
Config.RdmMinDistance = 8.0

-- VDM: Mindestgeschwindigkeit (m/s) beim Anfahren. 8 m/s ≈ 29 km/h.
Config.VdmMinSpeed = 8.0

-- Spawn-Kill: Sekunden nach Spawn/Join, in denen eine Toetung als Spawn-Kill gilt.
Config.SpawnKillSeconds = 15

-- NLR: Rueckkehr innerhalb dieser Minuten an den Todesort (Radius NlrReturnMeters)
-- ist ein NLR-Verstoss.
Config.NlrMinutes = 5
Config.NlrReturnMeters = 100.0

-- Discord-Webhook fuer Incident-Alerts. Leer = kein Discord (nur Konsole/Log).
-- >>> Hier deine Webhook-URL eintragen.
Config.DiscordWebhook = ''

-- ── Weltspur: Fahrzeuge ohne Insassen ──────────────────────────────────────
-- Der Beweisstrom kennt nur Spieler; ein Auto ist nur sichtbar, solange jemand
-- darin sitzt. Fuer einen Ueberfall (vorfahren, aussteigen, schiessen) fehlt sonst
-- genau das Fahrzeug. Aufgezeichnet wird nur Vernetztes (Spieler-/Dienst-/Skript-
-- fahrzeuge); die GTA-Bevoelkerung ist clientseitig. /rps_worlddiag zeigt den Fall.
Config.World = {
    -- Weltspur aufzeichnen. Braucht Config.DiskArchive = true (kein RAM-Ring).
    Vehicles = true,

    -- Abtastintervall (ms). 200 = 5 Hz.
    -- >>> Hoeher (100) macht Fahrten fluessiger und kostet mehr; niedriger (400)
    -- >>> spart, laesst enge Kurven aber sichtbar schneiden.
    IntervalMs = 200,

    -- Umkreis um Spieler (m), in dem Fahrzeuge mitlaufen. Gerechnet ueber ein
    -- Zellenraster, nicht echte Abstaende — tatsaechlicher Umkreis 1 bis 2
    -- Zellbreiten. Gewollt: exakte Rechnung kostet bei 200 Spielern das
    -- Hundertfache ohne Nutzen fuer die Beweisfrage.
    Radius = 150.0,

    -- Skriptgespawnte Fussgaenger mitschreiben (Haendler, Wachen, Missions-NPCs).
    -- Erklaeren Unfaelle: wer auf die Strasse laeuft, erklaert ein Ausweichmanoever.
    Peds = true,

    -- Hoechstzahl gleichzeitig aufgezeichneter Fussgaenger, serverweit.
    MaxPeds = 128,

    -- Hoechstzahl gleichzeitig aufgezeichneter Fahrzeuge, serverweit. Deckel
    -- schuetzt Tickzeit UND Speicher; wird er wirksam, meldet /rps_vehdiag
    -- "gedeckelt". Messung 2026-08-18: 76 Fahrzeuge + 32 Peds = 0,10 ms/Durchlauf.
    MaxVehicles = 256,

    -- Spaetestens nach dieser Zeit einen Ankerpunkt fuer stehende Fahrzeuge
    -- schreiben, damit die Wiedergabe bei langem Stillstand einen Bezug hat.
    HeartbeatMs = 5000,

    -- Hoechstmenge Umgebungsdaten je Segment und Admin. Beweisstrom hat Vorrang,
    -- Umgebung fuellt den Rest; greift der Deckel, zeigt die Oberflaeche es
    -- (worldCapped) — nie stillschweigend kuerzen.
    MaxDeliverBytes = 98304,

    -- Deckel auf die STUECKZAHL. Ein parkendes Auto = ~50 Byte, aber ein eigener
    -- Plattenzugriff; ein reiner Byte-Deckel liesse fast 2000 zu und die
    -- Segment-Auslieferung zoege sich so lange, dass ein Beweissegment verloren
    -- ginge.
    MaxDeliverChunks = 128,
}

-- ── Szenenspur: die Sicht des Clients ──────────────────────────────────────
-- VERSUCHSSTAND. Noch nicht fuer den Regelbetrieb gedacht.
-- Der Server sieht nur Vernetztes; die GTA-Bevoelkerung entsteht je Client. Wer
-- sie im Replay sehen will, muss den Client fragen — das kostet: jeder Client
-- sieht SEINE Welt (Datenmenge waechst linear mit Spielerzahl), und ein
-- abstuerzender Client hoert auf zu melden (gerade bei Combat-Logging fatal).
-- Diese Spur ERGAENZT den server-autoritativen Beweisstrom, ersetzt ihn nicht;
-- die Oberflaeche weist die Herkunft aus.
Config.Scene = {
    -- Szenenspur aufzeichnen.
    -- >>> Vorher /rps_sceneprobe ausfuehren: misst 5 s, wieviel bei DIESEM Server anfaellt.
    Enabled = false,

    -- Umkreis (m) um die Kamera des Spielers.
    -- >>> 60 m deckt einen Vorfall ab; 100 m kostet ~das Dreifache ohne Mehrwert.
    Radius = 60.0,

    -- Abtastintervall (ms). 500 = 2 Hz.
    IntervalMs = 500,

    -- Was mitlaeuft.
    Vehicles = true,
    Peds     = true,
    -- Objekte sind fast immer unbewegtes Weltmobiliar und kosten am meisten.
    Objects  = false,

    -- Hoechstzahl Entitaeten je Durchlauf (schuetzt Client-Tickzeit/Datenmenge).
    MaxEntities = 40,

    -- Wie lange eine Entitaet nach Verlassen des Umkreises als "dieselbe" gilt.
    -- >>> Zu klein zerlegt eine Randfahrt in viele Spuren; zu gross laesst zwei
    -- >>> verschiedene Fahrzeuge verschmelzen.
    GraceMs = 1500,

    -- Eigenen Ped und sein Fahrzeug mitschreiben. In der reinen Clientsicht
    -- zwingend (das Replay zeigt genau, was dieser Client sah). Nur bei Source =
    -- 'both' waere er doppelt.
    IncludeSelf = true,

    -- Obergrenze je Spieler und Minute, serverseitig durchgesetzt (schuetzt die
    -- Ablage vor einem Client, der schneller sendet als vereinbart).
    MaxBytesPerMinute = 262144,

    -- Wirklich hochladen — oder nur messen. Getrennt von Enabled mit Absicht:
    -- erst misst man (/rps_scenestat zeigt B/s und GB/Tag), dann entscheidet man.
    Upload = false,

    -- Groesse eines Uploads (Byte) und Abstand zwischen zwei Uploads (ms).
    MaxBatchBytes = 16384,
    UploadMs      = 2000,

    -- Ankerpunkt fuer stehende Objekte spaetestens nach dieser Zeit (wie Weltspur).
    HeartbeatMs = 5000,
}

-- ── Playback (3D-Wiedergabe) ───────────────────────────────────────────────

Config.Playback = {
    -- Peds ueber Engine-Lokomotion laufen lassen (echte Beinbewegung) statt nur
    -- verschieben. Natuerlicher, kann bei sprunghaften Aufzeichnungen nachlaufen.
    -- false = harte Positionierung (gleitet, aber exakt).
    Locomotion = true,

    -- Abstand (m) Klon↔Soll, ab dem hart nachkorrigiert wird. Kleiner = exakter,
    -- groesser = fluessiger.
    DriftCorrection = 2.5,

    -- Raeder der Fahrzeugklone drehen lassen.
    -- >>> AUS, bewusste Entscheidung: bei framegenau gesetzter Position laesst sich
    -- >>> die Radrotation nicht darstellen (kein direkter Schreibkanal, der
    -- >>> Physik-Umweg macht das Replay unreproduzierbar). Nicht wieder aufmachen.
    VehicleWheelSpin = false,

    -- Woher der Geschwindigkeitsvektor stammt (Klon wird gesetzt, nicht gefahren;
    -- Geschwindigkeit ist nur Eingang des Radmodells):
    --   'track'   = Betrag+Richtung aus der Bahn inkl. Hochachse (auch Schleudern/rueckwaerts)
    --   'heading' = Betrag aus Format, Richtung aus Blickrichtung, Hochachse 0
    --   'none'    = keine Geschwindigkeit setzen
    -- >>> Auf 'none', sobald /rps_wheeldiag einen Positionsvorlauf > 0,05 m meldet.
    VehicleVelocitySource = 'none',

    -- Handbremse/Bremsdruck jeden Frame loesen (sitzt jemand drin ohne Fahrauftrag,
    -- haelt die Engine das Rad sonst fest).
    VehicleReleaseBrakes = false,

    -- Vorlauf herausrechnen, den die gesetzte Geschwindigkeit erzeugt (Engine
    -- integriert sie trotzdem; Versatz aus dem Vorframe wird vom Ziel abgezogen).
    -- >>> Nur abschalten, wenn Fahrzeuge sichtbar nachlaufen (/rps_wheeldiag).
    VehicleLeadCompensation = false,

    -- Zweiter Schreibweg auf die Radrotation ueber SetVehicleForwardSpeed.
    -- >>> Aus, wenn Fahrzeuge im Replay sichtbar zucken.
    VehicleWheelPush = false,

    -- Wie stark Fahrzeugklone an der Physik teilnehmen (Radrotation braucht
    -- eingeschaltete Kollision; Klon wird dabei gegen Zuschauer/andere isoliert):
    --   'collision' = volle Physik mit Bodenabtastung, Raeder drehen sich
    --   'keep'      = Physikobjekt, keine Kollision, keine Rotation
    --   'off'       = ganz aus der Physikwelt, ruhigstes Bild, keine Rotation
    -- >>> Auf 'off', wenn Fahrzeuge im Replay sichtbar zittern.
    VehiclePhysicsMode = 'off',

    -- VERSUCHSSCHALTER: Fahrzeug eines Beteiligten wie ein Umgebungsfahrzeug
    -- aufbauen (eingefroren, Motor aus). Beide aus denselben Serverdaten/Code,
    -- Unterschied nur Ped/Freeze/Motor.
    -- >>> /rps_wheelcmp misst beide 3 s nebeneinander.
    VehicleFreeze = false,

    -- WOHER die Umgebung im Replay kommt:
    --   'server' — was der Server sah (server/vehicles.lua). Autoritativ, eine Quelle.
    --   'client' — nur was der verfolgte Spieler meldete (client/scene.lua).
    --              Reicher, aber client-gemeldet; Beweisstrom-Klone werden NICHT
    --              gebaut, sonst stuende jeder Beteiligte doppelt.
    --   'both'   — beides uebereinander, nur zum Vergleichen.
    -- >>> Fuer den Regelbetrieb ist 'server' die belastbare Einstellung.
    Source = 'server',

    -- ── Fahrzeuge FAHREN statt versetzen ───────────────────────────────────
    -- Wichtigste Einstellung fuers Aussehen. Aus: jeder Klon wird framegenau (2 cm)
    -- auf seine Position gesetzt, schwebt aber ueber die Strasse. An: Geschwindigkeit
    -- aus der Bahn vorgegeben, Physik rechnet den Rest — Raeder drehen, Positions-
    -- fehler steigt auf einige Dezimeter.
    -- >>> Fuer ein Entscheidungswerkzeug richtig: halber Meter Versatz aendert keine
    -- >>> Bewertung, ein unglaubwuerdiges Bild jede. Vermessen: aus + Datenband lesen.
    VehicleDrive = true,

    -- Ab dieser Abweichung (m) wird nachgeregelt; darunter rollt der Klon frei
    -- (jede Korrektur waere sichtbares Zittern).
    DriveCorrectionSoft = 0.6,

    -- Staerke der Nachregelung (1/s). Nur noch fuer die Hoehenkorrektur im Flug.
    DriveCorrectionGain = 4.0,

    -- Nachregelung in FAHRTRICHTUNG: holt Rueckstand auf der Bahn auf.
    -- >>> Hoeher holt schneller auf, kann ruckeln; niedriger laesst hinterherfahren.
    DriveAlongGain = 1.5,

    -- Nachregelung SEITLICH (zurueck auf die Linie). Bewusst niedrig — zu hoch
    -- sieht wieder aus wie seitliches Rutschen.
    DriveCrossGain = 1.2,

    -- Ab dieser Abweichung (m) hart setzen statt regeln (echter Teleport/Respawn
    -- in der Aufzeichnung oder verkeilter Klon).
    DriveTeleportAt = 8.0,

    -- SPRUNG: ab dieser senkrechten Geschwindigkeit (m/s) gilt das Fahrzeug als in
    -- der Luft und die Wiedergabe gibt die Hochachse vor (sonst faehrt der Klon
    -- durch die Schanze statt abzuheben).
    -- >>> Zu niedrig huepft er an Bordsteinen, zu hoch klebt er bei flachen Spruengen.
    DriveAirborneVz = 2.0,

    -- Nachlauf des Flugzustands (ms). Am Scheitel geht Vz durch null; ohne Nachlauf
    -- faellt der Klon dort aus dem Flug und klatscht in der Luft auf.
    DriveAirborneHoldMs = 600,

    -- Spultempo von A/D in der Folgekamera (s Aufnahme je s Tastendruck). 6 = 6x.
    SeekHoldSpeed = 6.0,

    -- Wetter und Uhrzeit der Aufzeichnung wiederherstellen.
    RestoreWorldState = true,

    -- Namensschilder ueber den Klonen anzeigen.
    ShowNameTags = true,

    -- Lebende Bevoelkerung waehrend der Wiedergabe unterdruecken (Ambient-Verkehr
    -- des Zuschauers sieht aus wie Klone und fuehrt bei Ausweichmanoever-Bewertung
    -- in die Irre).
    -- >>> Nur abschalten, wenn eine leere Szene stoerender ist als eine falsche.
    SuppressAmbient = true,

    -- Sekunden ohne Daten, bis ein Klon abgeraeumt wird. Gezaehlt nur bei
    -- NACHGEWIESENER Abwesenheit — ein Klon ohne aktuell geladene Daten bleibt
    -- stehen (sonst nicht unterscheidbar: nicht da vs. Daten fehlten).
    ActorDespawnSeconds = 20.0,

    -- Hoechstzahl gleichzeitiger Klone (verfolgter Spieler + naechste Beteiligte
    -- haben Vorrang). Greift der Deckel, zeigt die Oberflaeche es an.
    MaxClones = 24,

    -- Zustandsbalken unter dem Namen (Health/Weste; beim Verfolgten auch Zahlen).
    ShowStatusBars = true,

    -- Hoechstzahl dargestellter UMGEBUNGSFAHRZEUGE (Weltspur). Zaehlt getrennt von
    -- MaxClones, sonst verdraengte ein voller Parkplatz die Beteiligten.
    -- >>> 0 blendet die Umgebung aus, ohne die Aufzeichnung abzuschalten.
    MaxWorldVehicles = 20,

    -- Zeitbudget je Bild fuers Dekodieren der Weltspur (ms). Getrennt von
    -- DecodeBudgetMs, damit die Umgebung dem Beweisstrom keine Zeit wegnimmt.
    WorldDecodeBudgetMs = 0.7,
}

-- ── Sicherheit ─────────────────────────────────────────────────────────────

-- Max. Groesse eines Reporter-Uploads (Byte). Groesseres wird verworfen und als
-- Manipulationsversuch geflaggt. 1-s-Batch ≈ 200 B; 4 KB ist grosszuegig.
Config.MaxReporterBytes = 4096

-- ── Fidelity: Daten vom Client (§4.1) ──────────────────────────────────────
-- Client meldet, was der Server nicht sieht: Bewegungszustand, Blickrichtung mit
-- Neigung, Fahrzeugdetails (Blinker/Licht). Hebt die Optik deutlich.
-- >>> Client-gemeldet und damit faelschbar: dient der Darstellung, NIE als Beweis
-- >>> (Oberflaeche kennzeichnet die Herkunft). Ohne bleibt das Replay funktionsfaehig.
Config.Fidelity = true

-- Abtastrate des Fidelity-Stroms (ms). 100 = 10 Hz, unter 0,1 ms Client-Tickzeit.
Config.FidelityIntervalMs = 100

-- ── Interne Konstanten (nicht aendern) ─────────────────────────────────────

-- Routing-Bucket-Basis fuer Replay-Instanzen. Hoch gewaehlt, um nicht mit d-dl
-- (5000) oder anderen Instancing-Resources zu kollidieren.
Config.ReplayBucketBase = 9000
