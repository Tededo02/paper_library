# Paper Library

App nativa per macOS per organizzare articoli scientifici in corsi, importare da arXiv o PDF locali, leggere e annotare i documenti e generare riassunti AI sul Mac. La libreria è salvata in locale; l’interfaccia è in inglese.

## Requisiti

- macOS 26 o successivo.
- Xcode completo con SDK macOS 27 (verificato con Xcode 27.2); i soli Command Line Tools non bastano.
- Per i riassunti AI: Mac compatibile con Apple Intelligence, funzione attiva e modello disponibile.

## Installazione

Scarica o clona il repository, apri il Terminale nella cartella del progetto ed esegui:

```sh
bash Scripts/build-app.sh release
open "build/release/Paper Library.app"
```

Per aggiornare, chiudi l’app e ripeti i comandi. La libreria rimane in `~/Library/Application Support/local.paperlibrary.app/`.

Per verificare il progetto: `bash Scripts/verify.sh`. Dettagli in [ARCHITECTURE.md](ARCHITECTURE.md) e [Documentation](Documentation/).
