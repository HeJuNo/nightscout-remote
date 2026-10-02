# Nightscout Remote

Native iOS-App (SwiftUI) zum schnellen Eintragen von **Kohlenhydraten** und **Blutzuckerwerten** in [Nightscout](https://nightscout.github.io/).

## Funktionen

- **Schnell-Buttons** für KH (Standard: 2 g, 4 g, 6 g, 14 g) – frei anpassbar, sortierbar, bis zu 12 Buttons
- **Manuelle KH-Eingabe** für beliebige Werte
- **Blutzucker-Eingabe** als „BG Check“ (Finger), wahlweise in mg/dL oder mmol/L
- Einträge **ohne Absorptionszeit**, markiert mit `enteredBy: "Nightscout Remote"`
- **Warteschlange**: Fehlgeschlagene Uploads werden gespeichert und mit ursprünglicher Uhrzeit automatisch nachgeholt (bei Netzwerkrückkehr, App-Aktivierung, alle 60 s)
- **Hintergrund-Upload**: Laufende Übertragungen werden nach dem Schließen der App noch abgeschlossen
- **Verbindungstest**: prüft Erreichbarkeit, Lese- und Schreibrechte des Tokens
- **Verlauf** (eigener Tab): KH- und BZ-Einträge dieser App der letzten **30 Tage**, nach Tagen gruppiert (Heute, Gestern, Datum), neueste zuerst. Einträge von Loop oder anderen Apps werden nicht angezeigt; ältere Einträge mit `enteredBy: "Nightscout KH App"` sind enthalten
- **Wer hat eingetragen?** Jeder Eintrag zeigt im Verlauf den Namen des Access Tokens (Subjekt in Nightscout), mit dem er angelegt wurde. Die App speichert ihn beim Hochladen im Feld `subject`; ältere Einträge ohne dieses Feld erscheinen als „Unbekannt“
- **Einträge löschen**: im Verlauf nach links wischen oder lange drücken → bestätigen. Der Eintrag wird endgültig aus Nightscout entfernt (benötigt das Recht `api:treatments:delete`, siehe Voraussetzungen)
- **Aktualisieren** des Verlaufs bei jedem Tab-Wechsel, per Herunterziehen oder über den Knopf oben rechts
- **Access-Token-Anmeldung** (JWT über `/api/v2/authorization/request`), Token sicher im iOS-Schlüsselbund

## Voraussetzungen

- iOS 18.0 oder neuer
- Nightscout-Instanz (mit API v2 / Version 14+ empfohlen)
- Access Token aus Nightscout: *Admin-Werkzeuge → Subjekt hinzufügen*, Rolle **careportal** (Schreiben) und **readable** (Lesen)
- Zum **Löschen** im Verlauf zusätzlich das Recht `api:treatments:delete`, z.B. über die Rolle **admin** oder eine eigene Rolle. Fehlt es, zeigt der Verlauf einen Hinweis; Eintragen funktioniert weiterhin

## Projektstruktur

```
Sources/
  App/      App-Einstieg, Keychain-Helfer
  Models/   Nightscout-API, Warteschlange, Button-Speicher, ViewModels (Eintragen, Verlauf)
  Views/    Tab-Leiste (Eintragen/Verlauf), Hauptbildschirm, Verlauf, Einstellungen, Warteschlangen-Ansicht
Assets.xcassets/     App-Icon
project.yml          XcodeGen-Projektdefinition
fastlane/            Fastfile + Matchfile (Signieren, Bauen, TestFlight-Upload)
.github/workflows/   GitHub-Actions fuer den Browser-Build
```

Keine externen Swift-Abhaengigkeiten – nur Apple-Frameworks.

---

# Browser-Build: ohne Mac direkt nach TestFlight

Der Ablauf entspricht dem Browser-Build von [LoopWorkspace](https://github.com/LoopKit/LoopWorkspace):
GitHub Actions baut die App auf einem macOS-Server, signiert sie mit **fastlane match** und laedt sie zu **TestFlight** hoch.

> **Du baust schon Loop, Trio oder LoopFollow per Browser-Build?**
> Dann hast du die 6 Secrets und das Repository `Match-Secrets` bereits – verwende einfach dieselben Werte und springe zu Schritt 3.

## Voraussetzungen

- Kostenpflichtiger Apple-Developer-Account (99 USD/Jahr)
- GitHub-Account
- Dieses Repository in deinem GitHub-Account (am besten **privat**)

## 1. Die 6 Secrets beschaffen

| Secret | Woher |
|---|---|
| `TEAMID` | [developer.apple.com/account](https://developer.apple.com/account) → Mitgliedschaft → *Team-ID* (10 Zeichen) |
| `FASTLANE_ISSUER_ID` | [App Store Connect → Benutzer und Zugriff → Integrationen → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) → *Issuer-ID* |
| `FASTLANE_KEY_ID` | Dort einen **Teamschluessel** mit Rolle **Admin** erzeugen → *Schluessel-ID* |
| `FASTLANE_KEY` | Die heruntergeladene `.p8`-Datei in einem Texteditor oeffnen und den **kompletten Inhalt** kopieren (inkl. `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`) |
| `GH_PAT` | [github.com/settings/tokens](https://github.com/settings/tokens) → *Generate new token (classic)* → Ablauf **No expiration**, Berechtigungen **repo** und **workflow** |
| `MATCH_PASSWORD` | Frei ausgedachtes Passwort – verschluesselt deine Zertifikate. **Gut aufbewahren!** |

Die `.p8`-Datei kann nur **einmal** heruntergeladen werden – sicher ablegen.

## 2. Secrets im Repository eintragen

Repository → **Settings → Secrets and variables → Actions → Tab „Secrets“ → New repository secret**
und alle 6 Secrets mit exakt diesen Namen anlegen.

Optional im Tab **„Variables“**:

| Variable | Wirkung |
|---|---|
| `ENABLE_NUKE_CERTS` = `true` | Abgelaufenes Distribution-Zertifikat wird automatisch widerrufen und neu erstellt (empfohlen) |
| `FORCE_NUKE_CERTS` = `true` | Erzwingt einmalig die Neuerstellung (danach wieder loeschen) |
| `BUNDLE_ID` | Eigene Bundle-ID statt `com.<TEAMID>.nightscoutremote` |
| `APP_VERSION` | Versionsnummer, z.B. `1.1.0` (Standard: `1.0.0`) |
| `SCHEDULED_BUILD` = `false` | Automatischen Monats-Build abschalten |

## 3. Workflows nacheinander starten

Repository → Tab **Actions** (beim ersten Mal: *I understand my workflows, go ahead and enable them*).
Links den Workflow auswaehlen → **Run workflow**.

1. **1. Secrets pruefen** – prueft alle Secrets und legt das private Repository `Match-Secrets` automatisch an.
2. **2. Bundle-ID anlegen** – registriert `com.<TEAMID>.nightscoutremote` bei Apple.
3. **App in App Store Connect anlegen** (einmalig, manuell):
   [App Store Connect → Apps](https://appstoreconnect.apple.com/apps) → **+** → *Neue App*
   - Plattform: iOS
   - Name: z.B. `Nightscout Remote` (muss im App Store eindeutig sein – ggf. Zusatz wie `Nightscout Remote HL`)
   - Primaere Sprache: Deutsch
   - Bundle-ID: `Nightscout Remote – com.<TEAMID>.nightscoutremote` auswaehlen
   - SKU: beliebig, z.B. `nightscoutremote`
   - Benutzerzugriff: Vollzugriff
4. **3. Zertifikate erstellen** – erzeugt Distribution-Zertifikat und Profil (in `Match-Secrets`).
5. **4. Nightscout Remote bauen** – baut, signiert und laedt nach TestFlight hoch (ca. 10–20 Minuten).

Danach erscheint der Build nach etwas Verarbeitungszeit in App Store Connect unter **TestFlight**.
Dort unter *Interne Tests* eine Gruppe anlegen, dich selbst hinzufuegen und den Build zuweisen –
anschliessend in der **TestFlight-App** auf dem iPhone installieren.

## Automatische Builds

Workflow 4 laeuft zusaetzlich **am 1. jedes Monats** automatisch.
TestFlight-Builds sind nur **90 Tage** gueltig – so hast du immer einen aktuellen Build.
Die Build-Nummer wird automatisch hochgezaehlt; Zertifikate werden vor jedem Build geprueft.

## Fehlersuche

- Rote Fehlermeldungen stehen oben in der Zusammenfassung des Workflow-Laufs.
- Das komplette Xcode-Protokoll und die IPA liegen als Download unter **Artifacts → build-artifacts**.
- *„required agreement“*: Neue Apple-Vereinbarung auf [developer.apple.com/account](https://developer.apple.com/account) akzeptieren.
- *„Couldn't decrypt the repo“*: `MATCH_PASSWORD` stimmt nicht mit dem Passwort ueberein, mit dem `Match-Secrets` erstellt wurde.
- *„Could not find app … on App Store Connect“*: Schritt 3 (App anlegen) fehlt oder Bundle-ID passt nicht.

## Lokal bauen (optional, mit Mac)

```bash
brew install xcodegen
xcodegen generate
open NightscoutRemote.xcodeproj
```

In Xcode unter *Signing & Capabilities* das eigene Team waehlen.

## Hinweis

Diese App ist kein Medizinprodukt. Therapieentscheidungen bitte nicht allein auf Basis dieser App treffen.
