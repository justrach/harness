<p align="center"><img src="docs/brand/harness-icon.png" alt="Harness-App-Symbol" width="112"></p>

<h1 align="center">Harness</h1>

<p align="center">Ein nativer Arbeitsbereich für die Coding-Agents auf deinen Geräten.</p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · Deutsch · <a href="README.hindi.md">हिन्दी</a> · <a href="README.thai.md">ไทย</a> · <a href="README.indo.md">Bahasa Indonesia</a> · <a href="README.malay.md">Bahasa Melayu</a></p>

Harness vereint **CodeGraff (graff)**, Claude Code, Codex, Cursor, Devin, Grok,
Hermes, Pi, OpenCode und Antigravity in einer Desktop-Oberfläche. Du kannst
ohne Konto lokal beginnen und später Sitzungen mit vertrauenswürdigen Geräten
synchronisieren.

## Ein Blick in die App

| Agents auswählen | Sitzungen auf anderen Geräten verfolgen |
| :---: | :---: |
| <img src="docs/media/harness-settings/s2-agents-settings.png" alt="Agent-Einstellungen in Harness" width="520"> | <img src="docs/media/registry-sync/03-transcript-synced.png" alt="Synchronisierte Sitzung in Harness" width="520"> |

Modell und Arbeitsverzeichnis auswählen, Änderungen neben dem Chat prüfen
und Dateien oder den Browser direkt in Harness öffnen. Die Desktop-App nutzt
Rust und GPUI; die iOS-App zeigt synchronisierte Sitzungen in SwiftUI an.

### Mit CodeGraff verbunden

Harness enthält einen eigenen Adapter für [CodeGraff](https://github.com/justrach/codegraff).
Symbol und Illustration unten stammen aus dem CodeGraff-Projekt; ihre Herkunft
steht in den [Hinweisen zu Drittanbietern](THIRD_PARTY_NOTICES.md).

<p align="center"><img src="docs/brand/codegraff-emblem.png" alt="CodeGraff-Symbol" width="92"> <img src="docs/brand/codegraff-workshop.png" alt="CodeGraff-Werkstatt" width="188"></p>

## Aus dem Quellcode starten

Verwende die Rust-Version aus [`rust-toolchain.toml`](rust-toolchain.toml).

| System | Befehl |
| --- | --- |
| macOS | `./scripts/run-macos-dev.sh` |
| Linux | `cargo build -p harness && ./target/debug/harness` |
| Windows | `cargo run --locked -p harness` |

Das macOS-Skript startet `target/macos-dev/Harness.app`. Für eine Offline-Demo
mit Beispielsitzungen: `./scripts/dev-demo.sh`. Hinweise zu [Windows](docs/reference/windows-development.md)
und zum [Linux-Browser](docs/reference/linux-browser.md) stehen in der Dokumentation.

## So funktioniert Harness

Jeder Desktop betreibt eine eigene Engine und speichert lokale Sitzungen selbst.
`harness` öffnet die Oberfläche; `harness headless` betreibt die Engine ohne
Fenster. Installierte Agents werden auf `PATH` gefunden und in Einstellungen →
Agents angezeigt. Mehr dazu: [Architektur](ARCHITECTURE.md).

Die Synchronisierung ist optional. Für den Wechsel zu einem synchronisierten
Profil die Engine zuerst anhalten:

```sh
harness daemon stop
harness login
harness daemon start
```

Geräte desselben Kontos können entfernte Arbeitsverzeichnisse lesen und
schreiben. **Show ignored files** umfasst auch ignorierte Dateien wie `.env`.
Melde deshalb nur Geräte an, denen du vertraust. Lokale Sitzungen bleiben im
lokalen Profil; mit `harness logout` und einem Neustart kehrst du dorthin zurück.

## Lizenz

Harness steht unter der [GNU Affero General Public License, Version 3](LICENSE)
(`AGPL-3.0-only`), derselben öffentlichen AGPL-Version wie CodeGraff.
Standard Harness Pte. Ltd. behält die Rechte an den eigenen Harness-Beiträgen;
frühere und fremde Beiträge behalten ihre jeweiligen Hinweise und Lizenzen.
Siehe [Hinweise zu Drittanbietern](THIRD_PARTY_NOTICES.md).
