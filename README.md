# Shizuko

Windows 11向けの音楽CD作成アプリです。Windows Media Playerに依存せず、Windows標準のIMAPI 2.0を使います。

## 起動

Windows PowerShell 5.1でこのフォルダを開き、次を実行します。

```powershell
.\Shizuko.ps1
```

## 対応範囲

- PCM WAV（44.1 kHz、16 bit、ステレオ。WAVE_FORMAT_EXTENSIBLE形式を含む）の追加
- ドラッグ＆ドロップ（フォルダーを落とすと直下のWAVを名前順に追加）、曲順変更、合計時間表示
- 光学ドライブ選択とCD-R/CD-RWへの音楽CD書き込み

MP3などの圧縮形式や、他のWAV形式には対応していません。書き込みにはWindows標準のIMAPI 2.0とADODB.Streamを利用します。書き込みはバックグラウンドで行い、書き込み中は操作とアプリの終了ができません。

Smart App Controlや組織のアプリ制御ポリシーがスクリプトをブロックする環境では起動できない場合があります。このアプリは制御を回避しません。
