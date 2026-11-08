---
title: NP21i サポート / Support
---

# NP21i サポート

NP21i は iPhone・iPad で動く PC-98 シリーズのエミュレータです（NP2kai をもとにした非公式の移植版）。

## はじめに

1. ファイル App →「このiPhone内」/「このiPad内」→ **NP21i** → `sdlnp21kai` に、お持ちの実機から吸い出した BIOS などの ROM（`BIOS.ROM`, `ITF.ROM`, `FONT.ROM` ほか）を置きます。ROM がなくても内蔵の互換 BIOS で起動できるソフトもあります。
2. ディスクイメージ（`.hdi` `.nhd` `.d88` `.fdi` など）をファイル App や共有シートから NP21i で開くと、フロッピードライブに入れるか、ハードディスクとしてつなぐかを選べます。
3. 画面下の ≡ メニューから設定・使い方・リセットなどを開けます。アプリ内の「使い方」に詳しい説明があります。

FONT.ROM がない場合は、iOS のフォント（ヒラギノ）から文字を作ります。`sdlnp21kai` に `default.ttf` を置くと、そのフォントを使います。

## MIDI

設定 →「MIDI」で出力先・入力元を選びます。Bluetooth MIDI 機器は同じ画面の「Bluetooth MIDI 機器」で接続します。
ほかのアプリからは「NP21i MIDI OUT」「NP21i MIDI IN」でつなげます。MIDI 機器がなくても、出力先を「内蔵音源」にして SoundFont（.sf2）か DLS（.dls）を追加すると鳴らせます。

## お問い合わせ・不具合の報告

[GitHub の Issues](https://github.com/mikuta0407/NP21i/issues) にお書きください。iOS のバージョン、機種、何をしたらどうなったかを書いていただけると助かります。
ROM やソフトウェアの入手についてはお答えできません。

---

# NP21i Support (English)

NP21i is an emulator of the NEC PC-98 series for iPhone and iPad, an unofficial port of NP2kai. The user interface is in Japanese.

- Put ROM files dumped from your own machine (`BIOS.ROM`, `ITF.ROM`, `FONT.ROM`, …) in Files → On My iPhone / iPad → **NP21i** → `sdlnp21kai`. Some software starts with the built-in compatible BIOS, without ROMs.
- Open disk images (`.hdi`, `.nhd`, `.d88`, `.fdi`, …) with NP21i from Files or the share sheet to insert them as floppy disks or connect them as hard disks.
- MIDI: Settings → MIDI. Other apps can connect to "NP21i MIDI OUT" / "NP21i MIDI IN".

Questions and bug reports: [GitHub Issues](https://github.com/mikuta0407/NP21i/issues). We cannot help with obtaining ROMs or software.

[プライバシーポリシー / Privacy Policy](privacy.html)
