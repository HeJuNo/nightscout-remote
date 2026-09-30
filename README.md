# Nightscout Remote

Native iOS-App (SwiftUI) zum schnellen Eintragen von **Kohlenhydraten** und **Blutzuckerwerten** in [Nightscout](https://nightscout.github.io/).

## Funktionen

- **Schnell-Buttons** für KH (Standard: 2 g, 4 g, 6 g, 15 g) – frei anpassbar, sortierbar, bis zu 12 Buttons
- **Manuelle KH-Eingabe** für beliebige Werte
- **Blutzucker-Eingabe** als „BG Check“ (Finger), wahlweise in mg/dL oder mmol/L
- Einträge **ohne Absorptionszeit**, markiert mit `enteredBy: "Nightscout Remote"`
- **Warteschlange**: Fehlgeschlagene Uploads werden gespeichert und mit ursprünglicher Uhrzeit automatisch nachgeholt (bei Netzwerkrückkehr, App-Aktivierung, alle 60 s)
- **Hintergrund-Upload**: Laufende Übertragungen werden nach dem Schließen der App noch abgeschlossen
- **Verbindungstest**: prüft Erreichbarkeit, Lese- und Schreibrechte des Tokens
- **Access-Token-Anmeldung** (JWT über `/api/v2/authorization/request`), Token sicher im iOS-Schlüsselbund

## Voraussetzungen

- iOS 18.0 oder neuer
- Nightscout-Instanz (mit API v2 / Version 14+ empfohlen)
- Access Token aus Nightscout: *Admin-Werkzeuge → Subjekt hinzufügen*, Rolle **careportal** (Schreiben) und **readable** (Lesen)

## Projektstruktur

```
Sources/
  App/      App-Einstieg, Konfiguration, Keychain-Helfer
  Models/   Nightscout-API, Warteschlange, Button-Speicher, ViewModel
  Views/    Hauptbildschirm, Einstellungen, Warteschlangen-Ansicht
Assets.xcassets/   App-Icon
project.yml        XcodeGen-Projektdefinition
```

## Bauen

Das Xcode-Projekt wird mit [XcodeGen](https://github.com/yonaskolb/XcodeGen) aus `project.yml` erzeugt:

```bash
brew install xcodegen
xcodegen generate
open NightscoutKhApp.xcodeproj
```

Keine externen Abhängigkeiten – nur Apple-Frameworks.

## Hinweis

Diese App ist kein Medizinprodukt. Therapieentscheidungen bitte nicht allein auf Basis dieser App treffen.
