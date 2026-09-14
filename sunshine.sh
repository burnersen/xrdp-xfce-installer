#!/usr/bin/env bash
#
# ==========================================================
#  Sunshine auf einem Server ohne Bildschirm
#  mit eigener, zweiter Arbeitsflaeche
#
#  Ubuntu 20.04 und neuer
# ==========================================================
#
#  WAS DAS SKRIPT BAUT
#
#    sunshine-xorg.service      Xorg (dummy) :20   der Bildschirm
#      +- sunshine-desktop.service   XFCE darauf
#           +- sunshine-stream.service   Sunshine streamt ihn
#
#  Dazu eine virtuelle Tonausgabe ueber PipeWire, weil der
#  Server keine Soundkarte hat und der Stream sonst stumm bliebe.
#
#  Der RDP-Zugang bleibt unberuehrt. Es entsteht eine ZWEITE
#  Arbeitsflaeche neben der von RDP: gleiche Dateien, aber
#  getrennt laufende Programme.
#
#  WARUM XORG UND NICHT XVFB
#
#  Xvfb nimmt keine Eingabegeraete an. Sunshine legt Maus und
#  Tastatur erst beim Verbinden als virtuelle uinput-Geraete
#  an - unter Xvfb laufen die ins Leere. Ergebnis waere: Bild
#  kommt an, nichts laesst sich bedienen. Xorg mit dem Treiber
#  "dummy" ist ein vollwertiger X-Server ohne Grafikkarte und
#  erkennt neue Eingabegeraete ueber udev.
#
#  WICHTIG FUER DEN CLIENT (sonst bewegt sich die Maus nicht!)
#
#  In Moonlight muss "Maus fuer Remotedesktop optimieren"
#  AUSGESCHALTET sein. Mit dieser Einstellung sendet Moonlight
#  absolute Positionen, die bei Sunshine nicht ankommen.
#  Der Hinweis steht am Ende noch einmal.
#
#  WAS NICHT ANGEFASST WIRD
#
#    /etc/xrdp/ ... , /etc/X11/xorg.conf , /etc/X11/xorg.conf.d/
#
#  Von jeder Datei, die veraendert wird, liegt vorher eine
#  Sicherungskopie in /root/setup-backup.
# ==========================================================

set -Eeuo pipefail


# ----------------------------------------------------------
# KONSTANTEN
# ----------------------------------------------------------

readonly SICHERUNG_ORDNER="/root/setup-backup"
readonly XORG_KONFIG="/etc/X11/xorg-dummy.conf"
readonly XWRAPPER_KONFIG="/etc/X11/Xwrapper.config"
readonly UINPUT_MODUL_KONFIG="/etc/modules-load.d/uinput.conf"
readonly DIENST_ORDNER="/etc/systemd/system"

# Anzeigen unter :20 gehoeren den RDP-Sitzungen (die zaehlen ab :10 hoch).
readonly KLEINSTE_ANZEIGE=20
readonly GROESSTE_ANZEIGE=99

# Wie lange auf einen startenden X-Server gewartet wird.
readonly WARTEN_MAX_SEKUNDEN=40

# Name der virtuellen Tonausgabe. Der Server hat keine Soundkarte;
# ohne dieses Geraet bliebe der Stream stumm.
readonly TON_GERAET="sunshine_sink"

# Ordner fuer die getrennten Profile der Zweitstarter.
# BEWUSST OHNE PUNKT am Anfang: Programme aus einem Snap-Paket (unter
# Ubuntu z. B. Firefox) duerfen versteckte Ordner im Heimatverzeichnis
# nicht lesen. Mit einem Punkt davor wuerde der Firefox-Starter scheitern.
readonly ZWEITPROFIL_ORDNER_NAME="sunshine-zweitprofile"


# ----------------------------------------------------------
# FEHLERBEHANDLUNG
# ----------------------------------------------------------

bei_fehler() {
    local rueckgabewert=$?

    # Schlaegt ein Befehl in einer Kommandosubstitution fehl, laeuft dieser
    # Trap zweimal (Unterschale + Hauptlauf). Die Unterschale meldet nichts.
    if [[ "$BASHPID" != "$$" ]]; then
        exit "$rueckgabewert"
    fi

    echo >&2
    echo "==================================================" >&2
    echo " ABBRUCH: Die Einrichtung ist fehlgeschlagen." >&2
    echo " Zeile:   $1" >&2
    echo " Befehl:  $2" >&2
    echo " Code:    $rueckgabewert" >&2
    echo >&2
    echo " Sicherungskopien liegen in $SICHERUNG_ORDNER" >&2
    echo "==================================================" >&2

    exit "$rueckgabewert"
}

trap 'bei_fehler "$LINENO" "$BASH_COMMAND"' ERR


# ----------------------------------------------------------
# KLEINE HELFER
# ----------------------------------------------------------

schritt() {
    echo
    echo "=== $* ==="
}

hinweis() {
    echo "    $*"
}

warnung() {
    echo "    ACHTUNG: $*"
}

sichern() {
    local datei="$1"

    if [[ ! -f "$datei" ]]; then
        return 0
    fi

    cp -a "$datei" "$SICHERUNG_ORDNER/$(basename "$datei").$ZEITSTEMPEL"
    hinweis "Sicherung: $(basename "$datei").$ZEITSTEMPEL"
}

# Wartet, bis der X-Server auf der Anzeige antwortet.
warte_auf_bildschirm() {
    local sekunde

    for (( sekunde = 1; sekunde <= WARTEN_MAX_SEKUNDEN; sekunde++ )); do

        if DISPLAY=":$ANZEIGE_NUMMER" xdpyinfo >/dev/null 2>&1; then
            echo
            return 0
        fi

        printf '.'
        sleep 1

    done

    echo
    return 1
}


# ----------------------------------------------------------
# VORPRUEFUNGEN
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "FEHLER: Bitte als root ausfuehren (sudo -i)." >&2
    exit 1
fi

if ! true </dev/tty 2>/dev/null; then
    echo "FEHLER: Das Skript stellt Fragen und braucht ein Terminal." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "FEHLER: /etc/os-release nicht gefunden." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "FEHLER: Dieses Skript ist fuer Ubuntu gedacht." >&2
    exit 1
fi

# Ohne XFCE gibt es nichts zu uebertragen. Lieber hier abbrechen als
# nach der halben Installation.
if [[ ! -x /usr/bin/xfce4-session ]]; then
    echo "FEHLER: /usr/bin/xfce4-session nicht gefunden." >&2
    echo "Dieses Skript setzt eine vorhandene XFCE-Arbeitsflaeche voraus." >&2
    echo "Nachinstallieren mit:  apt-get install -y xfce4" >&2
    exit 1
fi

ZEITSTEMPEL="$(date +%Y%m%d_%H%M%S)"
readonly ZEITSTEMPEL

echo "=================================================="
echo " Sunshine mit eigener Arbeitsflaeche einrichten"
echo "=================================================="
echo
echo " System:     ${PRETTY_NAME:-Ubuntu}"
echo " Architektur: $(dpkg --print-architecture)"
echo
echo " Es entsteht eine ZWEITE Arbeitsflaeche neben der von"
echo " RDP. Dateien sind dieselben, die laufenden Programme"
echo " nicht. An der RDP-Einrichtung wird nichts geaendert."
echo

if [[ ! -d /dev/dri ]]; then
    echo " Hinweis: keine Grafikkarte gefunden. Das Bild wird vom"
    echo " Hauptprozessor berechnet. Fuer Arbeitsflaeche und Video"
    echo " reicht das, zum Spielen nicht."
    echo
fi


# ----------------------------------------------------------
# FRAGEN
# ----------------------------------------------------------

read -rp "Benutzer, dem die Sunshine-Arbeitsflaeche gehoert: " \
    BENUTZER < /dev/tty

if [[ -z "$BENUTZER" ]]; then
    echo "FEHLER: Kein Benutzer angegeben." >&2
    exit 1
fi

if ! id "$BENUTZER" >/dev/null 2>&1; then
    echo "FEHLER: Benutzer '$BENUTZER' gibt es nicht." >&2
    exit 1
fi

BENUTZER_UID="$(id -u "$BENUTZER")"

if (( BENUTZER_UID < 1000 )); then
    echo "FEHLER: '$BENUTZER' ist ein Systemkonto (UID $BENUTZER_UID)." >&2
    exit 1
fi

BENUTZER_GRUPPE="$(id -gn "$BENUTZER")"
BENUTZER_HEIM="$(getent passwd "$BENUTZER" | cut -d: -f6)"

if [[ -z "$BENUTZER_HEIM" || ! -d "$BENUTZER_HEIM" ]]; then
    echo "FEHLER: Heimatverzeichnis von '$BENUTZER' nicht gefunden." >&2
    exit 1
fi

readonly BENUTZER BENUTZER_UID BENUTZER_GRUPPE BENUTZER_HEIM

echo

read -rp "Nummer der Anzeige [$KLEINSTE_ANZEIGE]: " \
    ANZEIGE_NUMMER < /dev/tty

ANZEIGE_NUMMER="${ANZEIGE_NUMMER:-$KLEINSTE_ANZEIGE}"

if ! [[ "$ANZEIGE_NUMMER" =~ ^[0-9]+$ ]]; then
    echo "FEHLER: Bitte eine Zahl angeben." >&2
    exit 1
fi

if (( ANZEIGE_NUMMER < KLEINSTE_ANZEIGE || ANZEIGE_NUMMER > GROESSTE_ANZEIGE )); then
    echo "FEHLER: Bitte eine Zahl zwischen $KLEINSTE_ANZEIGE und $GROESSTE_ANZEIGE." >&2
    echo "Kleinere Nummern gehoeren den RDP-Sitzungen." >&2
    exit 1
fi

if [[ -e "/tmp/.X11-unix/X${ANZEIGE_NUMMER}" ]]; then
    echo "FEHLER: Anzeige :$ANZEIGE_NUMMER ist schon belegt." >&2
    exit 1
fi

readonly ANZEIGE_NUMMER

echo

read -rp "Aufloesung [1920x1080]: " AUFLOESUNG < /dev/tty

AUFLOESUNG="${AUFLOESUNG:-1920x1080}"

if ! [[ "$AUFLOESUNG" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
    echo "FEHLER: Ungueltige Aufloesung. Beispiel: 1920x1080" >&2
    exit 1
fi

BILD_BREITE="${AUFLOESUNG%x*}"
BILD_HOEHE="${AUFLOESUNG#*x}"

readonly AUFLOESUNG BILD_BREITE BILD_HOEHE

echo

read -rp "Zugriff auf eine einzelne IPv4-Adresse beschraenken? [J/n]: " \
    ANTWORT_FIREWALL < /dev/tty

ANTWORT_FIREWALL="${ANTWORT_FIREWALL:-J}"

ERLAUBTE_IP=""

if [[ "$ANTWORT_FIREWALL" =~ ^[JjYy]$ ]]; then

    while true; do

        read -rp "Erlaubte oeffentliche IPv4-Adresse: " \
            ERLAUBTE_IP < /dev/tty

        if [[ "$ERLAUBTE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            break
        fi

        echo "Ungueltig. Beispiel: 203.0.113.10"

    done

elif ! [[ "$ANTWORT_FIREWALL" =~ ^[Nn]$ ]]; then

    echo "FEHLER: Bitte j oder n antworten." >&2
    exit 1

fi

readonly ERLAUBTE_IP

echo
echo "Manche Programme (Browser, Mailprogramm) laufen je Benutzer nur"
echo "EINMAL. Sind sie schon auf der RDP-Flaeche offen, tut sich hier"
echo "beim Start nichts. Dagegen koennen eigene Starter mit getrenntem"
echo "Profil angelegt werden."
echo

read -rp "Solche Zweitstarter anlegen? [J/n]: " \
    ANTWORT_STARTER < /dev/tty

ANTWORT_STARTER="${ANTWORT_STARTER:-J}"

if [[ "$ANTWORT_STARTER" =~ ^[JjYy]$ ]]; then
    STARTER_ANLEGEN=true
elif [[ "$ANTWORT_STARTER" =~ ^[Nn]$ ]]; then
    STARTER_ANLEGEN=false
else
    echo "FEHLER: Bitte j oder n antworten." >&2
    exit 1
fi

readonly STARTER_ANLEGEN

mkdir -p "$SICHERUNG_ORDNER"


# ----------------------------------------------------------
# 1 - PAKETE
# ----------------------------------------------------------

schritt "[1/10] Pakete installieren"

export DEBIAN_FRONTEND=noninteractive

apt-get update

# xserver-xorg-video-dummy  der Bildschirm ohne Grafikkarte
# xserver-xorg-input-libinput  damit Eingabegeraete angenommen werden
# x11-utils / xinput  fuer die Pruefungen am Ende
# python3-evdev  erzeugt das Testgeraet fuer die Abnahme
apt-get install -y \
    xserver-xorg-core \
    xserver-xorg-video-dummy \
    xserver-xorg-input-libinput \
    x11-xserver-utils \
    x11-utils \
    xinput \
    python3-evdev \
    dbus-x11 \
    curl \
    ca-certificates


# ----------------------------------------------------------
# 2 - SUNSHINE
#
# Ueber die Paketquelle des Herstellers statt per fester
# Download-Adresse: Dateinamen enthalten die Versionsnummer
# und wuerden mit der naechsten Ausgabe nicht mehr stimmen.
# ----------------------------------------------------------

schritt "[2/10] Sunshine installieren"

if command -v sunshine >/dev/null 2>&1; then

    hinweis "Sunshine ist schon installiert."

else

    curl -1sLf \
        'https://dl.cloudsmith.io/public/lizardbyte/stable/cfg/setup/bash.deb.sh' \
        | bash

    apt-get update
    apt-get install -y sunshine

fi

# Der mitgelieferte Benutzerdienst wuerde sich irgendeinen Bildschirm
# suchen. Hier laufen eigene Dienste, also den mitgelieferten abschalten.
systemctl --global disable \
    app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1 || true


# ----------------------------------------------------------
# 3 - EINGABEGERAETE
#
# Ohne das Modul uinput gibt es kein /dev/uinput, und ohne das
# kann Sunshine keine virtuelle Maus anlegen. Der Eintrag in
# modules-load.d sorgt dafuer, dass es den Neustart uebersteht.
# ----------------------------------------------------------

schritt "[3/10] Eingabegeraete vorbereiten"

modprobe uinput 2>/dev/null || true

echo uinput > "$UINPUT_MODUL_KONFIG"

if [[ ! -e /dev/uinput ]]; then
    echo "FEHLER: /dev/uinput fehlt. Ohne das geht keine Eingabe." >&2
    echo "Erlaubt der Anbieter dieser Maschine eigene Kernelmodule?" >&2
    exit 1
fi

hinweis "$(ls -l /dev/uinput)"

if getent group input >/dev/null 2>&1; then

    if [[ " $(id -nG "$BENUTZER") " == *" input "* ]]; then
        hinweis "$BENUTZER ist in der Gruppe input."
    else
        usermod -aG input "$BENUTZER"
        hinweis "$BENUTZER zur Gruppe input hinzugefuegt."
    fi

fi


# ----------------------------------------------------------
# 4 - BILDSCHIRM-KONFIGURATION
#
# Eigener Dateiname mit Absicht: diese Datei liest nur der
# eigene Xorg-Aufruf. Eine Datei namens xorg.conf oder ein
# Schnipsel in xorg.conf.d wuerde auch von den xrdp-Sitzungen
# gelesen und koennte den RDP-Zugang zerstoeren.
# ----------------------------------------------------------

schritt "[4/10] Bildschirm einrichten"

sichern "$XORG_KONFIG"

# Die Zeitwerte einer Bildschirmzeile ("Modeline") haengen von der
# Aufloesung ab. Ein fester Wert waere nur fuer 1920x1080 richtig und
# wuerde bei jeder anderen Angabe ein falsches Bild ergeben, deshalb
# wird sie mit cvt passend berechnet.
MODELINE_ZEILE=""
MODUS_NAME="${BILD_BREITE}x${BILD_HOEHE}"

if command -v cvt >/dev/null 2>&1; then
    MODELINE_ZEILE="$(cvt "$BILD_BREITE" "$BILD_HOEHE" 60 \
        | grep '^Modeline' || true)"
fi

if [[ -n "$MODELINE_ZEILE" ]]; then

    # cvt nennt den Modus z. B. "1920x1080_60.00" - genau dieser Name
    # muss unten bei "Modes" wieder auftauchen.
    MODUS_NAME="$(awk '{ gsub(/"/, "", $2); print $2 }' <<< "$MODELINE_ZEILE")"
    hinweis "Bildschirmzeile berechnet: $MODUS_NAME"

else

    # Rueckfallebene, falls cvt fehlt: Standardwerte fuer 1920x1080.
    MODELINE_ZEILE='Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync'
    MODUS_NAME="1920x1080"
    warnung "cvt nicht gefunden - es wird 1920x1080 verwendet."

fi

readonly MODELINE_ZEILE MODUS_NAME

cat > "$XORG_KONFIG" <<EOF
# Virtueller Bildschirm fuer Sunshine auf Anzeige :$ANZEIGE_NUMMER.
# Angelegt am $(date '+%d.%m.%Y %H:%M').
#
# Diese Datei liest NUR der eigene Xorg-Aufruf
# (-config $(basename "$XORG_KONFIG")).
# Sie darf NICHT xorg.conf heissen und NICHT in xorg.conf.d liegen.

Section "ServerFlags"
    # MUSS "true" bleiben. Sunshine legt Maus und Tastatur erst beim
    # Verbinden als uinput-Geraete an. Mit "false" - wie es in vielen
    # Anleitungen steht - werden sie verworfen und nichts laesst sich
    # bedienen.
    Option "AutoAddDevices" "true"
EndSection

Section "Device"
    Identifier  "DummyDevice"
    Driver      "dummy"
    VideoRam    256000
EndSection

Section "Monitor"
    Identifier  "DummyMonitor"
    HorizSync   5.0 - 1000.0
    VertRefresh 5.0 - 200.0
    $MODELINE_ZEILE
EndSection

Section "Screen"
    Identifier   "DummyScreen"
    Device       "DummyDevice"
    Monitor      "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "$MODUS_NAME"
        Virtual $BILD_BREITE $BILD_HOEHE
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "DummyLayout"
    Screen 0 "DummyScreen"
EndSection
EOF

# Gegenprobe auf Vollstaendigkeit. Eine halb geschriebene Datei faellt
# sonst erst auf, wenn der Bildschirm merkwuerdig aussieht.
ANZAHL_SECTION="$(grep -c '^Section' "$XORG_KONFIG" || true)"
ANZAHL_ENDSECTION="$(grep -c '^EndSection' "$XORG_KONFIG" || true)"

if (( ANZAHL_SECTION != 5 || ANZAHL_ENDSECTION != 5 )); then
    echo "FEHLER: $XORG_KONFIG ist unvollstaendig" >&2
    echo "(Section: $ANZAHL_SECTION, EndSection: $ANZAHL_ENDSECTION, erwartet je 5)." >&2
    exit 1
fi

hinweis "$XORG_KONFIG geschrieben und geprueft."

# Ohne allowed_users=anybody darf ein Dienstbenutzer keinen X-Server
# starten. Nur diese eine Zeile wird angefasst - die Datei kann weitere
# Eintraege enthalten, die xrdp braucht.
sichern "$XWRAPPER_KONFIG"

if [[ ! -f "$XWRAPPER_KONFIG" ]]; then

    printf 'allowed_users=anybody\n' > "$XWRAPPER_KONFIG"
    hinweis "$XWRAPPER_KONFIG angelegt."

elif grep -q '^allowed_users=anybody' "$XWRAPPER_KONFIG"; then

    hinweis "Start-Erlaubnis steht schon richtig."

elif grep -q '^allowed_users=' "$XWRAPPER_KONFIG"; then

    sed -i 's/^allowed_users=.*/allowed_users=anybody/' "$XWRAPPER_KONFIG"
    hinweis "Start-Erlaubnis auf 'anybody' geaendert."

else

    printf 'allowed_users=anybody\n' >> "$XWRAPPER_KONFIG"
    hinweis "Start-Erlaubnis ergaenzt."

fi


# ----------------------------------------------------------
# 5 - TON
#
# Der Server hat keine Soundkarte. Ohne Tonsystem und ohne ein
# Ausgabegeraet haetten Programme nichts, wohin sie ausgeben
# koennen, und Sunshine nichts aufzunehmen - der Stream waere
# stumm.
#
# PipeWire liefert beides: das Tonsystem und eine virtuelle
# Ausgabe. Weil sie das einzige Ausgabegeraet ist, wird sie von
# allein zur Standardausgabe; Programme finden sie also ohne
# weiteres Zutun.
# ----------------------------------------------------------

schritt "[5/10] Ton einrichten"

apt-get install -y \
    pipewire \
    pipewire-pulse \
    wireplumber \
    pulseaudio-utils

# systemctl und pactl im Namen des Benutzers aufrufen. Beide brauchen
# dessen Laufzeitverzeichnis, sonst finden sie seine Dienste nicht.
#
# runuser statt sudo: es gehoert zu util-linux und ist auf jedem System
# vorhanden, waehrend sudo ein eigenes Paket ist.
als_benutzer() {
    runuser -u "$BENUTZER" -- env \
        XDG_RUNTIME_DIR="/run/user/$BENUTZER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$BENUTZER_UID/bus" \
        "$@"
}

# Die virtuelle Ausgabe dauerhaft anlegen. Ein "pactl load-module" waere
# nach dem naechsten Neustart wieder verschwunden.
PIPEWIRE_KONFIG_ORDNER="$BENUTZER_HEIM/.config/pipewire/pipewire.conf.d"

mkdir -p "$PIPEWIRE_KONFIG_ORDNER"

cat > "$PIPEWIRE_KONFIG_ORDNER/99-sunshine-sink.conf" <<EOF
# Virtuelle Tonausgabe fuer Sunshine.
# Angelegt am $(date '+%d.%m.%Y %H:%M').
context.objects = [
    {   factory = adapter
        args = {
            factory.name     = support.null-audio-sink
            node.name        = "$TON_GERAET"
            node.description = "Sunshine Ton"
            media.class      = Audio/Sink
            object.linger    = true
            audio.position   = [ FL FR ]
        }
    }
]
EOF

chown -R "$BENUTZER:$BENUTZER_GRUPPE" "$BENUTZER_HEIM/.config/pipewire"

# Die Tondienste des Benutzers einschalten. Der Zusatz add-wants ist
# noetig, weil sie sonst an graphical-session.target haengen - und das
# wird nie erreicht, wenn die Arbeitsflaeche als Systemdienst laeuft.
for TON_DIENST in pipewire.socket pipewire-pulse.socket wireplumber.service; do
    als_benutzer systemctl --user enable "$TON_DIENST" >/dev/null 2>&1 || true
done

for TON_DIENST in pipewire.service pipewire-pulse.service wireplumber.service; do
    als_benutzer systemctl --user add-wants default.target "$TON_DIENST" \
        >/dev/null 2>&1 || true
done

als_benutzer systemctl --user daemon-reload >/dev/null 2>&1 || true

for TON_DIENST in pipewire pipewire-pulse wireplumber; do
    als_benutzer systemctl --user restart "$TON_DIENST" >/dev/null 2>&1 || true
done

# PipeWire braucht einen Moment, bis das Geraet steht.
sleep 4

TON_GERAETE="$(als_benutzer pactl list short sinks 2>/dev/null || true)"

if [[ "$TON_GERAETE" == *"$TON_GERAET"* ]]; then
    hinweis "Tonausgabe '$TON_GERAET' ist da."
else
    warnung "Tonausgabe '$TON_GERAET' noch nicht sichtbar."
    warnung "Nach einem Neustart des Servers sollte sie erscheinen."
fi

# Sunshine sagen, welche Ausgabe es aufnehmen soll.
SUNSHINE_KONFIG="$BENUTZER_HEIM/.config/sunshine/sunshine.conf"

mkdir -p "$(dirname "$SUNSHINE_KONFIG")"

if [[ ! -f "$SUNSHINE_KONFIG" ]]; then
    : > "$SUNSHINE_KONFIG"
fi

sichern "$SUNSHINE_KONFIG"

if grep -q '^audio_sink' "$SUNSHINE_KONFIG"; then
    sed -i "s/^audio_sink.*/audio_sink = $TON_GERAET/" "$SUNSHINE_KONFIG"
else
    printf 'audio_sink = %s\n' "$TON_GERAET" >> "$SUNSHINE_KONFIG"
fi

chown -R "$BENUTZER:$BENUTZER_GRUPPE" "$BENUTZER_HEIM/.config/sunshine"

hinweis "In sunshine.conf eingetragen: audio_sink = $TON_GERAET"


# ----------------------------------------------------------
# 6 - DIENSTE
# ----------------------------------------------------------

schritt "[6/10] Dienste anlegen"

# Ein frueherer Aufbau mit Xvfb wuerde sich um dieselbe Anzeige streiten.
if [[ -f "$DIENST_ORDNER/sunshine-xvfb.service" ]]; then

    warnung "Alter Xvfb-Dienst gefunden - er wird abgeschaltet."
    systemctl disable --now sunshine-xvfb >/dev/null 2>&1 || true
    mv "$DIENST_ORDNER/sunshine-xvfb.service" \
       "$SICHERUNG_ORDNER/sunshine-xvfb.service.abgeloest.$ZEITSTEMPEL"

fi

# Damit die Dienste des Benutzers auch ohne Anmeldung laufen duerfen.
# Nebeneffekt: erst dadurch entsteht /run/user/<UID>, das die beiden
# Dienste unten als XDG_RUNTIME_DIR brauchen.
loginctl enable-linger "$BENUTZER" >/dev/null 2>&1 || true

for VERSUCH in 1 2 3 4 5; do
    [[ -d "/run/user/$BENUTZER_UID" ]] && break
    sleep 1
done

if [[ ! -d "/run/user/$BENUTZER_UID" ]]; then
    warnung "/run/user/$BENUTZER_UID fehlt - die Arbeitsflaeche koennte"
    warnung "beim ersten Start streiken. Notfalls Server neu starten."
fi

cat > "$DIENST_ORDNER/sunshine-xorg.service" <<EOF
[Unit]
Description=Xorg (dummy) als Bildschirm fuer Sunshine
After=network.target

[Service]
Type=simple
User=$BENUTZER
Group=$BENUTZER_GRUPPE
ExecStart=/usr/bin/Xorg :$ANZEIGE_NUMMER -config $(basename "$XORG_KONFIG") -nolisten tcp -noreset -ac
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$DIENST_ORDNER/sunshine-desktop.service" <<EOF
[Unit]
Description=XFCE-Arbeitsflaeche auf dem Sunshine-Bildschirm
After=sunshine-xorg.service
Requires=sunshine-xorg.service

[Service]
Type=simple
User=$BENUTZER
Group=$BENUTZER_GRUPPE
Environment=DISPLAY=:$ANZEIGE_NUMMER
Environment=XDG_RUNTIME_DIR=/run/user/$BENUTZER_UID
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/xfce4-session
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$DIENST_ORDNER/sunshine-stream.service" <<EOF
[Unit]
Description=Sunshine (Bildschirmuebertragung)
After=sunshine-desktop.service
Requires=sunshine-desktop.service

[Service]
Type=simple
User=$BENUTZER
Group=$BENUTZER_GRUPPE
Environment=DISPLAY=:$ANZEIGE_NUMMER
Environment=XDG_RUNTIME_DIR=/run/user/$BENUTZER_UID

# Sunshine haette seine Threads gern bevorzugt behandelt. Unter User=
# gehen die Rechte der Programmdatei verloren, deshalb beides hier:
# die Berechtigung selbst und die passende Obergrenze.
AmbientCapabilities=CAP_SYS_NICE
CapabilityBoundingSet=CAP_SYS_NICE
LimitNICE=-15

ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$DIENST_ORDNER"/sunshine-xorg.service \
           "$DIENST_ORDNER"/sunshine-desktop.service \
           "$DIENST_ORDNER"/sunshine-stream.service

systemctl daemon-reload

hinweis "sunshine-xorg, sunshine-desktop, sunshine-stream angelegt."


# ----------------------------------------------------------
# 7 - FIREWALL
#
# Moonlight braucht:
#   TCP 47984 (Kopplung), 47989 (Steuerung), 48010 (RTSP)
#   UDP 47998, 47999, 48000, 48002, 48010 (Bild und Ton)
#
# Port 47990 ist die Weboberflaeche und wird BEWUSST nicht
# geoeffnet: darueber laesst sich Sunshine umkonfigurieren.
# Sie wird vom Server selbst aus bedient.
# ----------------------------------------------------------

schritt "[7/10] Firewall einrichten"

if ! command -v ufw >/dev/null 2>&1; then

    warnung "ufw ist nicht installiert - keine Regeln gesetzt."

else

    regel_hinzufuegen() {
        local protokoll="$1"
        local port="$2"

        if [[ -n "$ERLAUBTE_IP" ]]; then
            ufw allow from "$ERLAUBTE_IP" to any port "$port" \
                proto "$protokoll" comment "Sunshine" >/dev/null
        else
            ufw allow "${port}/${protokoll}" comment "Sunshine" >/dev/null
        fi
    }

    for PORT in 47984 47989 48010; do
        regel_hinzufuegen tcp "$PORT"
    done

    for PORT in 47998 47999 48000 48002 48010; do
        regel_hinzufuegen udp "$PORT"
    done

    if [[ -n "$ERLAUBTE_IP" ]]; then
        hinweis "Zugriff nur von $ERLAUBTE_IP"
    else
        hinweis "Zugriff von jeder Adresse."
    fi

    hinweis "Port 47990 (Weboberflaeche) bleibt zu - so ist es gewollt."

fi


# ----------------------------------------------------------
# 8 - STARTEN
# ----------------------------------------------------------

schritt "[8/10] Dienste starten"

systemctl enable --now sunshine-xorg >/dev/null 2>&1

hinweis "Warte auf den Bildschirm"

if ! warte_auf_bildschirm; then
    echo "FEHLER: Anzeige :$ANZEIGE_NUMMER antwortet nicht." >&2
    echo "  journalctl -u sunshine-xorg -n 40 --no-pager" >&2
    exit 1
fi

systemctl enable --now sunshine-desktop >/dev/null 2>&1
sleep 6
systemctl enable --now sunshine-stream >/dev/null 2>&1
sleep 8


# ----------------------------------------------------------
# 9 - ABNAHME
#
# Der Beweis wird selbst erzeugt: ein eigenes uinput-Geraet.
# Taucht es in der Geraeteliste auf, nimmt der Bildschirm
# Eingaben an - ohne dass jemand streamen muss.
# ----------------------------------------------------------

schritt "[9/10] Abnahme"

ALLES_GUT=true

for DIENST in sunshine-xorg sunshine-desktop sunshine-stream; do

    if systemctl is-active --quiet "$DIENST"; then
        printf '    %-20s laeuft\n' "$DIENST:"
    else
        printf '    %-20s LAEUFT NICHT\n' "$DIENST:"
        ALLES_GUT=false
    fi

done

# Kein "exit" im awk und kein "head": ein Leser, der die Pipe frueh
# schliesst, laesst den Schreiber an SIGPIPE sterben (Code 141), was
# zusammen mit "set -o pipefail" faelschlich als Fehler gilt.
BILDGROESSE="$(DISPLAY=":$ANZEIGE_NUMMER" xdpyinfo \
    | awk '/dimensions:/ { print $2 }')"

hinweis "Bildgroesse: ${BILDGROESSE:-unbekannt}"

python3 - <<'PYTHON' &
import time
from evdev import UInput, ecodes as e

with UInput({e.EV_KEY: [e.BTN_LEFT], e.EV_REL: [e.REL_X, e.REL_Y]},
            name="Testmaus-Beweis"):
    time.sleep(15)
PYTHON

TEST_PROZESS=$!
sleep 4

# Bewusst ohne Pipe geprueft: "grep -q" steigt beim ersten Treffer aus
# und wuerde das Ergebnis unter "set -o pipefail" falsch negativ machen.
GERAETE_LISTE="$(DISPLAY=":$ANZEIGE_NUMMER" xinput list)"

if [[ "$GERAETE_LISTE" == *"Testmaus-Beweis"* ]]; then
    hinweis "Eingabe-Test: BESTANDEN"
else
    hinweis "Eingabe-Test: FEHLGESCHLAGEN"
    ALLES_GUT=false
fi

kill "$TEST_PROZESS" 2>/dev/null || true
wait "$TEST_PROZESS" 2>/dev/null || true

# Ton gegenpruefen. Ohne Ausgabegeraet bleibt der Stream stumm.
TON_GERAETE_JETZT="$(als_benutzer pactl list short sinks 2>/dev/null || true)"

if [[ "$TON_GERAETE_JETZT" == *"$TON_GERAET"* ]]; then
    hinweis "Ton-Test:    BESTANDEN ($TON_GERAET vorhanden)"
else
    hinweis "Ton-Test:    Ausgabe '$TON_GERAET' fehlt noch"
    warnung "Kein Abbruch - das gibt sich oft nach einem Neustart."
fi


# ----------------------------------------------------------
# 10 - ZWEITSTARTER
#
# Programme wie Browser lassen je Benutzer nur eine Instanz
# zu. Laeuft schon eine auf der RDP-Flaeche, reicht ein zweiter
# Aufruf seinen Wunsch einfach dorthin weiter - auf dieser
# Flaeche passiert dann scheinbar gar nichts.
#
# Abhilfe ist ein eigenes Profilverzeichnis je Programm.
# ----------------------------------------------------------

schritt "[10/10] Starter fuer zweite Sitzungen"

if [[ "$STARTER_ANLEGEN" != true ]]; then

    hinweis "Uebersprungen (so gewuenscht)."

else

    STARTER_ORDNER="$BENUTZER_HEIM/.local/share/applications"
    PROFIL_BASIS="$BENUTZER_HEIM/$ZWEITPROFIL_ORDNER_NAME"

    mkdir -p "$STARTER_ORDNER" "$PROFIL_BASIS"

    ANGELEGTE_STARTER=0

    # Legt einen Starter an, wenn das Programm vorhanden ist.
    #   $1 Programmbefehl, $2 Anzeigename, $3 Zusatzargumente, $4 Symbol
    starter_anlegen() {
        local befehl="$1"
        local anzeigename="$2"
        local argumente="$3"
        local symbol="$4"

        if ! command -v "$befehl" >/dev/null 2>&1; then
            return 0
        fi

        local datei="$STARTER_ORDNER/${befehl}-zweite-sitzung.desktop"

        cat > "$datei" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$anzeigename (zweite Sitzung)
Comment=Eigenes Profil, laeuft neben einer bereits geoeffneten Sitzung
Exec=$befehl $argumente
Icon=$symbol
Terminal=false
Categories=Network;
EOF

        chmod 0644 "$datei"
        hinweis "Starter angelegt: $anzeigename"
        ANGELEGTE_STARTER=$(( ANGELEGTE_STARTER + 1 ))
    }

    # Chrome und Verwandte: eigenes Datenverzeichnis genuegt.
    starter_anlegen google-chrome "Google Chrome" \
        "--user-data-dir=$PROFIL_BASIS/google-chrome" "google-chrome"

    starter_anlegen google-chrome-stable "Google Chrome" \
        "--user-data-dir=$PROFIL_BASIS/google-chrome" "google-chrome"

    starter_anlegen chromium "Chromium" \
        "--user-data-dir=$PROFIL_BASIS/chromium" "chromium"

    starter_anlegen chromium-browser "Chromium" \
        "--user-data-dir=$PROFIL_BASIS/chromium" "chromium-browser"

    starter_anlegen microsoft-edge "Microsoft Edge" \
        "--user-data-dir=$PROFIL_BASIS/edge" "microsoft-edge"

    starter_anlegen brave-browser "Brave" \
        "--user-data-dir=$PROFIL_BASIS/brave" "brave-browser"

    starter_anlegen vivaldi-stable "Vivaldi" \
        "--user-data-dir=$PROFIL_BASIS/vivaldi" "vivaldi"

    starter_anlegen code "Visual Studio Code" \
        "--user-data-dir=$PROFIL_BASIS/vscode" "code"

    # Firefox und Thunderbird brauchen zusaetzlich --no-remote, sonst
    # reichen sie den Aufruf trotz eigenem Profil weiter.
    starter_anlegen firefox "Firefox" \
        "--no-remote --profile $PROFIL_BASIS/firefox" "firefox"

    starter_anlegen thunderbird "Thunderbird" \
        "--no-remote --profile $PROFIL_BASIS/thunderbird" "thunderbird"

    chown -R "$BENUTZER:$BENUTZER_GRUPPE" "$STARTER_ORDNER" "$PROFIL_BASIS"

    # Damit die neuen Eintraege sofort im Menue auftauchen.
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$STARTER_ORDNER" >/dev/null 2>&1 || true
    fi

    if (( ANGELEGTE_STARTER == 0 )); then
        hinweis "Keines der bekannten Programme gefunden - nichts angelegt."
    else
        hinweis "$ANGELEGTE_STARTER Starter liegen im Menue unter 'Internet'."
    fi

    echo
    hinweis "Grenzen dieser Loesung, damit es spaeter nicht ueberrascht:"
    hinweis "- Die Starter erscheinen in BEIDEN Menues (gleiches Heimatverz.)."
    hinweis "- Das zweite Profil ist leer: eigene Lesezeichen, eigene Anmeldung."
    hinweis "- Nicht jedes Programm laesst sich so trennen. JDownloader,"
    hinweis "  pCloud und aehnliche sperren sich mit eigenen Dateien und"
    hinweis "  lassen sich nur auf EINER Flaeche betreiben."
    hinweis "- Einfachste Alternative bleibt: das Programm auf der anderen"
    hinweis "  Flaeche schliessen."

fi


# ----------------------------------------------------------
# ERGEBNIS
# ----------------------------------------------------------

echo
echo "=================================================="

if [[ "$ALLES_GUT" == true ]]; then
    echo " FERTIG"
else
    echo " FERTIG, ABER MIT PROBLEMEN (siehe oben)"
fi

echo "=================================================="
echo
echo " Benutzer:    $BENUTZER"
echo " Anzeige:     :$ANZEIGE_NUMMER"
echo " Aufloesung:  $AUFLOESUNG"

if [[ -n "$ERLAUBTE_IP" ]]; then
    echo " Erlaubte IP: $ERLAUBTE_IP"
else
    echo " Erlaubte IP: alle"
fi

echo
echo " +----------------------------------------------+"
echo " |  WICHTIG FUER MOONLIGHT                      |"
echo " |                                              |"
echo " |  In den Einstellungen des Clients            |"
echo " |                                              |"
echo " |    'Maus fuer Remotedesktop optimieren'      |"
echo " |                                              |"
echo " |  AUSSCHALTEN. Sonst sendet Moonlight         |"
echo " |  absolute Positionen, die hier nicht         |"
echo " |  ankommen - das Bild laeuft dann, aber der   |"
echo " |  Mauszeiger bewegt sich nicht.               |"
echo " +----------------------------------------------+"
echo
echo " NAECHSTE SCHRITTE"
echo
echo " 1. Weboberflaeche auf dem Server oeffnen:"
echo "      https://localhost:47990"
echo "    Entweder im Browser der RDP-Flaeche, oder von"
echo "    aussen durch einen Tunnel:"
echo "      ssh -L 47990:localhost:47990 root@<server>"
echo
echo "    Die Zertifikatswarnung ist normal (selbst ausgestellt)."
echo
echo " 2. Beim ersten Besuch Benutzername und Passwort fuer"
echo "    Sunshine festlegen und notieren."
echo
echo " 3. In Moonlight den Rechner ueber seine oeffentliche"
echo "    Adresse von Hand hinzufuegen."
echo
echo " 4. Die PIN-Seite der Weboberflaeche VOR dem Klick in"
echo "    Moonlight oeffnen. Sonst laufen die Versuche ab und"
echo "    blockieren sich gegenseitig (Fehler 409)."
echo
echo " NUETZLICHE BEFEHLE"
echo "   systemctl status sunshine-stream"
echo "   systemctl restart sunshine-stream"
echo "   journalctl -u sunshine-stream -n 50 --no-pager"
echo
echo "   Geraete waehrend einer Verbindung ansehen:"
echo "     DISPLAY=:$ANZEIGE_NUMMER xinput list"
echo
echo "   Tonausgabe pruefen (als $BENUTZER):"
echo "     XDG_RUNTIME_DIR=/run/user/$BENUTZER_UID pactl list short sinks"
echo
echo " ALLES WIEDER ENTFERNEN"
echo "   systemctl disable --now sunshine-stream sunshine-desktop sunshine-xorg"
echo "   rm -f $DIENST_ORDNER/sunshine-{xorg,desktop,stream}.service"
echo "   systemctl daemon-reload"
echo "   apt-get remove -y sunshine"
echo
echo " Der RDP-Zugang ist davon in keinem Fall betroffen."
echo
echo " Sicherungen dieses Laufs: $SICHERUNG_ORDNER/*.$ZEITSTEMPEL"
echo "=================================================="

[[ "$ALLES_GUT" == true ]]
