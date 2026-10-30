#requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:Tracks=[System.Collections.Generic.List[object]]::new()
function Read-Wav([string]$Path) {
 $s = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
 try {
  $r = [System.IO.BinaryReader]::new($s)
  if ([System.Text.Encoding]::ASCII.GetString($r.ReadBytes(4)) -ne 'RIFF') { throw 'RIFF WAVではありません。' }
  $riff = [long]$r.ReadUInt32()
  if ([System.Text.Encoding]::ASCII.GetString($r.ReadBytes(4)) -ne 'WAVE') { throw 'WAVEではありません。' }
  $end = if ($riff -lt 4) { $s.Length } else { [math]::Min($s.Length, 8 + $riff) }
  $fmt = $null; $off = -1L; $len = 0L
  while ($s.Position + 8 -le $end) {
   $id = [System.Text.Encoding]::ASCII.GetString($r.ReadBytes(4)); $n = [long]$r.ReadUInt32(); $st = $s.Position
   if ($st + $n -gt $end) { if ($null -ne $fmt -and $off -ge 0) { break }; throw 'WAVチャンクが壊れています。' }
   if ($id -eq 'fmt ') {
    if ($n -lt 16) { throw 'WAV形式情報が壊れています。' }
    $fmt = @{ Codec=$r.ReadUInt16(); Ch=$r.ReadUInt16(); Rate=$r.ReadUInt32(); ByteRate=$r.ReadUInt32(); Align=$r.ReadUInt16(); Bits=$r.ReadUInt16() }
   } elseif ($id -eq 'data') { $off = $st; $len = $n }
   $s.Position = $st + $n + ($n % 2)
  }
  if ($null -eq $fmt -or $off -lt 0) { throw 'WAVに音声データがありません。' }
  if ($fmt.Codec -ne 1 -or $fmt.Ch -ne 2 -or $fmt.Rate -ne 44100 -or $fmt.Bits -ne 16) { throw '対応形式はPCM、44.1 kHz、16 bit、ステレオです。' }
  if ($len % 4 -ne 0) { throw 'PCMデータサイズが不正です。' }
  [pscustomobject]@{ Path=$Path; Offset=$off; Length=$len; Seconds=($len / 176400.0) }
 } finally { $s.Dispose() }
}
$f=[System.Windows.Forms.Form]::new();$f.Text='Shizuko - 音楽CD作成';$f.StartPosition='CenterScreen';$f.Size=[System.Drawing.Size]::new(820,600);$f.MinimumSize=[System.Drawing.Size]::new(720,510);$f.Font=[System.Drawing.Font]::new('Segoe UI',9)
$h=[System.Windows.Forms.Label]::new();$h.Text='Shizuko';$h.Font=[System.Drawing.Font]::new('Segoe UI Semibold',22);$h.Location=[System.Drawing.Point]::new(20,14);$h.AutoSize=$true;$f.Controls.Add($h)
$hint=[System.Windows.Forms.Label]::new();$hint.Text='PCM WAVから音楽CDを作成';$hint.Location=[System.Drawing.Point]::new(22,55);$hint.AutoSize=$true;$f.Controls.Add($hint)
$lv=[System.Windows.Forms.ListView]::new();$lv.Location=[System.Drawing.Point]::new(20,90);$lv.Size=[System.Drawing.Size]::new(765,330);$lv.Anchor='Top,Bottom,Left,Right';$lv.View='Details';$lv.FullRowSelect=$true;$lv.AllowDrop=$true
[void]$lv.Columns.Add('曲',440);[void]$lv.Columns.Add('時間',90);[void]$lv.Columns.Add('場所',220);$f.Controls.Add($lv)
$add=[System.Windows.Forms.Button]::new();$add.Text='WAVを追加';$add.Location=[System.Drawing.Point]::new(20,432);$add.Size=[System.Drawing.Size]::new(100,32);$add.Anchor='Bottom,Left';$f.Controls.Add($add)
$dl=[System.Windows.Forms.Label]::new();$dl.Text='ドライブ:';$dl.Location=[System.Drawing.Point]::new(135,438);$dl.AutoSize=$true;$dl.Anchor='Bottom,Left';$f.Controls.Add($dl)
$drive=[System.Windows.Forms.ComboBox]::new();$drive.DropDownStyle='DropDownList';$drive.Location=[System.Drawing.Point]::new(200,434);$drive.Size=[System.Drawing.Size]::new(310,28);$drive.Anchor='Bottom,Left';$f.Controls.Add($drive)
$time=[System.Windows.Forms.Label]::new();$time.Text='合計 00:00 / 80:00';$time.Location=[System.Drawing.Point]::new(520,438);$time.AutoSize=$true;$time.Anchor='Bottom,Right';$f.Controls.Add($time)
$status=[System.Windows.Forms.Label]::new();$status.Text='WAVを追加するか、画面にドラッグしてください。';$status.Location=[System.Drawing.Point]::new(22,523);$status.Size=[System.Drawing.Size]::new(430,28);$status.Anchor='Bottom,Left,Right';$f.Controls.Add($status)
$del=[System.Windows.Forms.Button]::new();$del.Text='削除';$del.Location=[System.Drawing.Point]::new(470,520);$del.Size=[System.Drawing.Size]::new(70,34);$del.Anchor='Bottom,Right';$f.Controls.Add($del)
$up=[System.Windows.Forms.Button]::new();$up.Text='上へ';$up.Location=[System.Drawing.Point]::new(542,520);$up.Size=[System.Drawing.Size]::new(55,34);$up.Anchor='Bottom,Right';$f.Controls.Add($up)
$down=[System.Windows.Forms.Button]::new();$down.Text='下へ';$down.Location=[System.Drawing.Point]::new(599,520);$down.Size=[System.Drawing.Size]::new(55,34);$down.Anchor='Bottom,Right';$f.Controls.Add($down)
$burn=[System.Windows.Forms.Button]::new();$burn.Text='書き込み';$burn.Location=[System.Drawing.Point]::new(657,518);$burn.Size=[System.Drawing.Size]::new(128,38);$burn.Anchor='Bottom,Right';$f.Controls.Add($burn)
function Refresh-List{$lv.BeginUpdate();$lv.Items.Clear();for($i=0;$i-lt$script:Tracks.Count;$i++){$t=$script:Tracks[$i];$x=[System.Windows.Forms.ListViewItem]::new(('{0}. {1}'-f($i+1),[IO.Path]::GetFileName($t.Path)));$s=[int][math]::Round($t.Seconds);[void]$x.SubItems.Add(('{0:D2}:{1:D2}'-f[int][math]::Floor($s/60),($s%60)));[void]$x.SubItems.Add([IO.Path]::GetDirectoryName($t.Path));[void]$lv.Items.Add($x)};$lv.EndUpdate();$sum=($script:Tracks|Measure-Object Seconds -Sum).Sum;if($null-eq$sum){$sum=0};$n=[int][math]::Ceiling($sum);$time.Text='合計 {0:D2}:{1:D2} / 80:00'-f[int][math]::Floor($n/60),($n%60);if($n-gt4800){$time.ForeColor=[Drawing.Color]::Firebrick}else{$time.ForeColor=[Drawing.SystemColors]::ControlText}}
function Add-Files([string[]]$paths){foreach($p in $paths){if([IO.Path]::GetExtension($p)-ine'.wav'-or($script:Tracks|Where-Object Path -eq $p)){continue};try{$script:Tracks.Add((Read-Wav $p))}catch{[void][System.Windows.Forms.MessageBox]::Show(('{0}: {1}'-f[IO.Path]::GetFileName($p),$_.Exception.Message),'追加できません')}};Refresh-List}
function Load-Drives{$drive.Items.Clear();try{$m=New-Object -ComObject IMAPI2.MsftDiscMaster2;for($i=0;$i-lt$m.Count;$i++){$id=$m.Item($i);$r=New-Object -ComObject IMAPI2.MsftDiscRecorder2;$r.InitializeDiscRecorder($id);$name=@($r.VolumePathNames)|Select-Object -First 1;if([string]::IsNullOrWhiteSpace($name)){$name='光学ドライブ'};[void]$drive.Items.Add([pscustomobject]@{Id=$id;Label=('{0} ({1} {2})'-f$name,"$($r.VendorId)".Trim(),"$($r.ProductId)".Trim())});[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($r)};$drive.DisplayMember='Label';if($drive.Items.Count){$drive.SelectedIndex=0}else{$status.Text='光学ドライブがありません。'};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($m)}catch{$status.Text='ドライブ取得エラー: '+$_.Exception.Message}}
$picker=[System.Windows.Forms.OpenFileDialog]::new();$picker.Filter='PCM WAV (*.wav)|*.wav';$picker.Multiselect=$true
$add.Add_Click({if($picker.ShowDialog()-eq'OK'){Add-Files $picker.FileNames}})
$del.Add_Click({foreach($i in @($lv.SelectedIndices|Sort-Object -Descending)){$script:Tracks.RemoveAt([int]$i)};Refresh-List})
$up.Add_Click({if($lv.SelectedIndices.Count-eq1){$i=$lv.SelectedIndices[0];if($i-gt0){$x=$script:Tracks[$i];$script:Tracks.RemoveAt($i);$script:Tracks.Insert($i-1,$x);Refresh-List;$lv.Items[$i-1].Selected=$true}}})
$down.Add_Click({if($lv.SelectedIndices.Count-eq1){$i=$lv.SelectedIndices[0];if($i-lt$script:Tracks.Count-1){$x=$script:Tracks[$i];$script:Tracks.RemoveAt($i);$script:Tracks.Insert($i+1,$x);Refresh-List;$lv.Items[$i+1].Selected=$true}}})
$f.AllowDrop=$true;$f.Add_DragEnter({if($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)){$_.Effect='Copy'}});$f.Add_DragDrop({Add-Files $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)})
$lv.Add_DragEnter({if($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)){$_.Effect='Copy'}});$lv.Add_DragDrop({Add-Files $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)})
$burn.Add_Click({
 $sum=($script:Tracks|Measure-Object Seconds -Sum).Sum
 if(!$script:Tracks.Count){[void][System.Windows.Forms.MessageBox]::Show('先にPCM WAVを追加してください。');return};if($sum-gt4800){[void][System.Windows.Forms.MessageBox]::Show('80分を超えています。');return};if($script:Tracks.Count-gt99){[void][System.Windows.Forms.MessageBox]::Show('CDの上限は99曲です。');return};if($null-eq$drive.SelectedItem){[void][System.Windows.Forms.MessageBox]::Show('書き込みドライブがありません。');return}
 if([System.Windows.Forms.MessageBox]::Show('空のCD-R/CD-RWを入れてください。書き込みを開始します。','確認','OKCancel','Question')-ne'OK'){return}
 $burn.Enabled=$false;$w=$null;$r=$null;$temps=[Collections.Generic.List[string]]::new()
 try{$r=New-Object -ComObject IMAPI2.MsftDiscRecorder2;$r.InitializeDiscRecorder($drive.SelectedItem.Id);$w=New-Object -ComObject IMAPI2.MsftDiscFormat2TrackAtOnce;$w.Recorder=$r;$w.ClientName='Shizuko';$w.PrepareMedia();$needed=0L;foreach($t in $script:Tracks){$needed += [math]::Ceiling($t.Length/2352.0)+150};if($needed-gt$w.FreeSectorsOnMedia){throw'ディスクの空き容量が足りません。'}
 for($i=0;$i-lt$script:Tracks.Count;$i++){$t=$script:Tracks[$i];$status.Text='書き込み中 {0}/{1}: {2}'-f($i+1),$script:Tracks.Count,[IO.Path]::GetFileName($t.Path);$f.Refresh();$raw=[IO.Path]::Combine([IO.Path]::GetTempPath(),('Shizuko-'+[guid]::NewGuid().ToString('N')+'.pcm'));$temps.Add($raw);$src=[IO.File]::OpenRead($t.Path);$dst=[IO.File]::Create($raw);try{$src.Position=$t.Offset;$left=$t.Length;$buf=New-Object byte[] 1048576;while($left-gt0){$n=$src.Read($buf,0,[int][math]::Min($buf.Length,$left));if($n-le0){throw'WAV読み込みエラー。'};$dst.Write($buf,0,$n);$left-=$n};$pad=(2352-$t.Length%2352)%2352;if($pad){$dst.Write((New-Object byte[] $pad),0,$pad)}}finally{$src.Dispose();$dst.Dispose()};$a=New-Object -ComObject ADODB.Stream;try{$a.Type=1;$a.Open();$a.LoadFromFile($raw);$w.AddAudioTrack($a)}finally{if($a.State-eq1){$a.Close()};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($a)}}
 $w.ReleaseMedia();$status.Text='完了';[void][System.Windows.Forms.MessageBox]::Show('音楽CDの書き込みが完了しました。','Shizuko')
 }catch{if($w){try{$w.ReleaseMedia()}catch{}};$status.Text='書き込みに失敗しました。';[void][System.Windows.Forms.MessageBox]::Show(('書き込みエラー: '+$_.Exception.Message),'エラー')
 }finally{foreach($x in $temps){Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue};if($w){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($w)};if($r){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($r)};$burn.Enabled=$true}
})
$f.Add_Shown({Load-Drives});[void]$f.ShowDialog()
