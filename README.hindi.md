<p align="center"><img src="docs/brand/harness-icon.png" alt="Harness ऐप आइकन" width="112"></p>

<h1 align="center">Harness</h1>

<p align="center">आपकी मशीनों पर चलने वाले कोडिंग एजेंटों के लिए एक नेटिव कार्यक्षेत्र।</p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · हिन्दी · <a href="README.thai.md">ไทย</a> · <a href="README.indo.md">Bahasa Indonesia</a> · <a href="README.malay.md">Bahasa Melayu</a></p>

Harness एक डेस्कटॉप इंटरफ़ेस में **CodeGraff (graff)**, Claude Code, Codex,
Cursor, Devin, Grok, Hermes, Pi, OpenCode और Antigravity को साथ लाता है। बिना
बिना खाते के स्थानीय रूप से शुरू करें। जब ज़रूरत हो, तभी भरोसेमंद डिवाइसों पर
सत्र सिंक करें।

## Harness के अंदर

| एजेंट चुनें | दूसरे डिवाइस पर वही सत्र देखें |
| :---: | :---: |
| <img src="docs/media/harness-settings/s2-agents-settings.png" alt="Harness की एजेंट सेटिंग" width="520"> | <img src="docs/media/registry-sync/03-transcript-synced.png" alt="सिंक हुआ Harness सत्र" width="520"> |

मॉडल चुनें, बातचीत के साथ बदलाव जाँचें और ऐप में ही फ़ाइलें व ब्राउज़र खोलें।
डेस्कटॉप ऐप Rust/GPUI पर बना है; iOS साथी ऐप SwiftUI में सिंक हुए सत्र दिखाता है।

### CodeGraff के साथ

Harness में [CodeGraff](https://github.com/justrach/codegraff) का विशेष एडाप्टर है।
नीचे का प्रतीक और चित्र CodeGraff से हैं; श्रेय [तृतीय-पक्ष सूचनाओं](THIRD_PARTY_NOTICES.md)
में दिया गया है।

<p align="center"><img src="docs/brand/codegraff-emblem.png" alt="CodeGraff प्रतीक" width="92"> <img src="docs/brand/codegraff-workshop.png" alt="CodeGraff कार्यशाला चित्र" width="188"></p>

## स्रोत से चलाएँ

[`rust-toolchain.toml`](rust-toolchain.toml) में दिए गए Rust संस्करण का उपयोग करें।

| प्लेटफ़ॉर्म | कमांड |
| --- | --- |
| macOS | `./scripts/run-macos-dev.sh` |
| Linux | `cargo build -p harness && ./target/debug/harness` |
| Windows | `cargo run --locked -p harness` |

macOS स्क्रिप्ट `target/macos-dev/Harness.app` खोलती है। उदाहरण सत्रों वाला
ऑफ़लाइन डेमो चलाने के लिए `./scripts/dev-demo.sh` उपयोग करें।
[Windows](docs/reference/windows-development.md) और [Linux ब्राउज़र](docs/reference/linux-browser.md)
के निर्देश अलग से उपलब्ध हैं।

## यह कैसे काम करता है

हर डेस्कटॉप अपनी इंजन चलाता है और स्थानीय सत्र वहीं रखता है। `harness` GUI
खोलता है; `harness headless` बिना विंडो के इंजन चलाता है। इंस्टॉल किए गए एजेंट
`PATH` से खोजे जाते हैं। और जानकारी [आर्किटेक्चर](ARCHITECTURE.md) में है।

सिंक वैकल्पिक है। सिंक खाते में जाने से पहले इंजन रोकें:

```sh
harness daemon stop
harness login
harness daemon start
```

एक ही खाते के भरोसेमंद डिवाइस दूसरे डिवाइस की कार्यक्षेत्र फ़ाइलें पढ़ और
बदल सकते हैं। **Show ignored files** चालू करने पर `.env` जैसी अनदेखी फ़ाइलें
भी उपलब्ध हो जाती हैं। पुराने स्थानीय सत्र स्थानीय प्रोफ़ाइल में रहते हैं;
`harness logout` के बाद इंजन दोबारा शुरू करके वहाँ लौटें।

## लाइसेंस

Harness [GNU Affero General Public License, संस्करण 3](LICENSE)
(`AGPL-3.0-only`) के अंतर्गत उपलब्ध है। CodeGraff का सार्वजनिक लाइसेंस भी
इसी AGPL संस्करण पर आधारित है। Standard Harness Pte. Ltd. के अधिकार केवल
उसके अपने योगदान पर हैं; अन्य सामग्री की मूल कॉपीराइट और लाइसेंस सूचनाएँ
[तृतीय-पक्ष सूचनाओं](THIRD_PARTY_NOTICES.md) में हैं।
