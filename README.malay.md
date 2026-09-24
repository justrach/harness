<p align="center"><img src="docs/brand/harness-icon.png" alt="Ikon aplikasi Harness" width="112"></p>

<h1 align="center">Harness</h1>

<p align="center">Ruang kerja natif untuk ejen pengekodan pada peranti anda.</p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · <a href="README.hindi.md">हिन्दी</a> · <a href="README.thai.md">ไทย</a> · <a href="README.indo.md">Bahasa Indonesia</a> · Bahasa Melayu</p>

Harness menyatukan **CodeGraff (graff)**, Claude Code, Codex, Cursor, Devin,
Grok, Hermes, Pi, OpenCode dan Antigravity dalam satu aplikasi desktop.
Mulakan secara setempat tanpa akaun. Hidupkan penyegerakan apabila anda mahu
mengikuti sesi daripada peranti lain yang dipercayai.

## Di dalam Harness

| Pilih ejen | Ikuti sesi yang sama pada peranti lain |
| :---: | :---: |
| <img src="docs/media/harness-settings/s2-agents-settings.png" alt="Tetapan ejen Harness" width="520"> | <img src="docs/media/registry-sync/03-transcript-synced.png" alt="Sesi Harness yang disegerakkan" width="520"> |

Pilih model, semak perubahan di sisi perbualan, serta buka fail dan pelayar
tanpa meninggalkan aplikasi. Desktop menggunakan Rust/GPUI; aplikasi iOS
menggunakan SwiftUI untuk memaparkan sesi yang disegerakkan.

### Bersama CodeGraff

Harness mempunyai penyesuai khusus untuk [CodeGraff](https://github.com/justrach/codegraff).
Lambang dan ilustrasi di bawah berasal daripada projek CodeGraff. Kreditnya
terdapat dalam [notis pihak ketiga](THIRD_PARTY_NOTICES.md).

<p align="center"><img src="docs/brand/codegraff-emblem.png" alt="Lambang CodeGraff" width="92"> <img src="docs/brand/codegraff-workshop.png" alt="Ilustrasi bengkel CodeGraff" width="188"></p>

## Jalankan daripada kod sumber

Gunakan versi Rust dalam [`rust-toolchain.toml`](rust-toolchain.toml).

| Platform | Perintah |
| --- | --- |
| macOS | `./scripts/run-macos-dev.sh` |
| Linux | `cargo build -p harness && ./target/debug/harness` |
| Windows | `cargo run --locked -p harness` |

Skrip macOS membuka `target/macos-dev/Harness.app`. Jalankan
`./scripts/dev-demo.sh` untuk demo luar talian dengan sesi contoh. Panduan
[Windows](docs/reference/windows-development.md) dan [pelayar Linux](docs/reference/linux-browser.md)
tersedia berasingan.

## Cara kerja

Setiap desktop menjalankan enjin sendiri dan menyimpan sesi setempat pada
peranti itu. `harness` membuka GUI; `harness headless` menjalankan enjin tanpa
tetingkap. Ejen yang dipasang ditemui melalui `PATH`. Lihat
[seni bina](ARCHITECTURE.md) untuk butiran.

Penyegerakan adalah pilihan. Hentikan enjin sebelum bertukar ke akaun segerak:

```sh
harness daemon stop
harness login
harness daemon start
```

Peranti dalam akaun yang sama boleh membaca dan menulis fail ruang kerja pada
peranti lain. **Show ignored files** turut mendedahkan fail seperti `.env`;
log masuk hanya pada peranti yang anda percayai. Sesi setempat lama kekal dalam
profil setempat. Jalankan `harness logout` dan mulakan semula enjin untuk
kembali ke profil tersebut.

## Lesen

Harness tersedia di bawah [GNU Affero General Public License versi 3](LICENSE)
(`AGPL-3.0-only`), versi AGPL yang juga menjadi lesen awam CodeGraff.
Standard Harness Pte. Ltd. mengekalkan hak ke atas sumbangan Harness miliknya
sendiri; bahan lain kekal dengan hak cipta dan lesen asalnya. Lihat
[notis pihak ketiga](THIRD_PARTY_NOTICES.md).
