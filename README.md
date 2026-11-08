# NP21i

iPhone・iPad で動く PC-98 シリーズ（PC-9801・PC-9821）のエミュレータです。
Neko Project 21/W のコードを含む [NP2kai](https://github.com/AZO234/NP2kai)（その 386 版の np21kai）をもとにした、非公式の移植版です。
CoreMIDI で USB・Bluetooth の MIDI 機器につながり、レコンポーザなどの音楽ソフトで使いやすいようにしています。

An unofficial iPhone / iPad port of NP2kai (np21kai), a PC-98 emulator that includes the code of Neko Project 21/W, with CoreMIDI support.

- [サポート / Support](https://mikuta0407.github.io/NP21i/)
- [プライバシーポリシー / Privacy Policy](https://mikuta0407.github.io/NP21i/privacy.html)

## 主な機能

- MIDI 出力・入力（MPU-PC98II、S-MPU）: USB・Bluetooth の MIDI 機器、ほかのアプリ（仮想ポート）、内蔵音源（SoundFont・DLS）
- MIDI クロックの送信
- ソフトウェアキーボード（PC-98 配列・音楽ソフト用・ゲーム用）、ハードウェアキーボード、マウス、トラックパッド、ゲームコントローラ
- iPhone Duo のラップトップ型の持ち方
- ディスクイメージの作成・取り込み、Z: ドライブ（ホストドライブ）、環境の切り替え、状態の保存
- FONT.ROM がなくても iOS のフォントで漢字を表示

BIOS などの ROM、OS、ソフトウェアは含みません。

## ビルド

Xcode と CMake（3.24 以降）が必要です。

```sh
git clone --recurse-submodules https://github.com/mikuta0407/NP21i.git
cd NP21i
scripts/apply-patches.sh          # patches/ を vendor/ のサブモジュールに当てる
cmake -S . -B build/ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS
open build/ios/NP21iOS.xcodeproj
```

- `scripts/make-ipa.sh`: 署名なしの IPA を `dist/` に作ります（LiveContainer などで試す用）。
- `scripts/make-release.sh --team <チーム ID> [--upload]`: 署名付きでアーカイブして App Store Connect 向けに書き出します。
- SDL3 が既定です。SDL2 でビルドするときは `-DNP21_SDL=2`。

上流のコードへの変更は `patches/<サブモジュール名>/` にパッチとして置いています。

## ライセンス

- `vendor/NP2kai`: ファイルごとに `vendor/NP2kai/LICENSES/` のとおり（大半は Neko Project II / 21/W の修正 BSD、NP2kai 独自部分は MIT）。
  GPL のファイル、fmgen、HAXM などはビルドから外しています。
- `vendor/SDL`, `vendor/SDL3`: zlib ライセンス。
- アプリ内の「ライセンス」に、使っているもののライセンス文をまとめて表示します（`scripts/make-licenses.sh`）。
- アプリのアイコンは NP2kai の `misc/np2.svg` をもとにしています。

PC-98、PC-9801、PC-9821 は日本電気株式会社の商標です。本プロジェクトは日本電気株式会社、Neko Project 21/W および NP2kai の開発者とは関係ありません。
