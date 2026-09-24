<p align="center"><img src="docs/brand/harness-icon.png" alt="Ikon aplikasi Harness" width="112"></p>

<h1 align="center">Harness</h1>

<p align="center">Ruang kerja native untuk agen pemrograman di perangkat Anda.</p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · <a href="README.hindi.md">हिन्दी</a> · <a href="README.thai.md">ไทย</a> · Bahasa Indonesia · <a href="README.malay.md">Bahasa Melayu</a></p>

Harness menyatukan **CodeGraff (graff)**, Claude Code, Codex, Cursor, Devin,
Grok, Hermes, Pi, OpenCode, dan Antigravity dalam satu aplikasi desktop.
Mulai secara lokal tanpa akun. Aktifkan sinkronisasi saat Anda ingin mengikuti
sesi dari perangkat lain yang tepercaya.

## Di dalam Harness

| Pilih agen | Bekerja dengan graff |
| :---: | :---: |
| <img src="docs/media/readme/codegraff-agents-dark.png" alt="Pengaturan agen Harness terbaru dalam tema Codegraff Dark" width="520"> | <img src="docs/media/readme/codegraff-chat-dark.png" alt="Contoh percakapan graff dalam tema Codegraff Dark" width="520"> |

Pilih model, tinjau perubahan di samping percakapan, serta buka berkas dan
peramban tanpa meninggalkan aplikasi. Desktop memakai Rust/GPUI; pendamping
iOS memakai SwiftUI untuk menampilkan sesi tersinkron.

### Terhubung dengan CodeGraff

Harness memiliki adaptor khusus untuk [CodeGraff](https://github.com/justrach/codegraff).
Lambang dan ilustrasi di bawah berasal dari proyek CodeGraff. Atribusinya ada
di [pemberitahuan pihak ketiga](THIRD_PARTY_NOTICES.md).

<p align="center"><img src="docs/brand/codegraff-emblem.png" alt="Lambang CodeGraff" width="92"> <img src="docs/brand/codegraff-workshop.png" alt="Ilustrasi bengkel CodeGraff" width="188"></p>

## Jalankan dari sumber

Gunakan versi Rust dalam [`rust-toolchain.toml`](rust-toolchain.toml).

| Platform | Perintah |
| --- | --- |
| macOS | `./scripts/run-macos-dev.sh` |
| Linux | `cargo build -p harness && ./target/debug/harness` |
| Windows | `cargo run --locked -p harness` |

Skrip macOS membuka `target/macos-dev/Harness.app`. Jalankan
`./scripts/dev-demo.sh` untuk demo offline dengan sesi contoh. Petunjuk
[Windows](docs/reference/windows-development.md) dan [peramban Linux](docs/reference/linux-browser.md)
tersedia terpisah.

## Cara kerja

Setiap desktop menjalankan mesin sendiri dan menyimpan sesi lokal di perangkat
tersebut. `harness` membuka GUI; `harness headless` menjalankan mesin tanpa
jendela. Agen yang terpasang ditemukan melalui `PATH`. Lihat
[arsitektur](ARCHITECTURE.md) untuk rincian.

Sinkronisasi bersifat opsional. Hentikan mesin sebelum beralih ke akun sinkron:

```sh
harness daemon stop
harness login
harness daemon start
```

Perangkat dalam akun yang sama dapat membaca dan menulis berkas ruang kerja
perangkat lain. **Show ignored files** juga membuka akses ke berkas seperti
`.env`; masuklah hanya di perangkat yang Anda percayai. Sesi lokal lama tetap
ada di profil lokal. Jalankan `harness logout`, lalu mulai ulang mesin untuk
kembali ke profil tersebut.

## Lisensi

Harness tersedia dengan [GNU Affero General Public License versi 3](LICENSE)
(`AGPL-3.0-only`), versi AGPL yang juga digunakan sebagai lisensi publik
CodeGraff. Standard Harness Pte. Ltd. mempertahankan hak atas kontribusi
Harness miliknya sendiri; materi lain tetap membawa hak cipta dan lisensi
asalnya. Lihat [pemberitahuan pihak ketiga](THIRD_PARTY_NOTICES.md).
