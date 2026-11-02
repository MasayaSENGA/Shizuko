#requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:Tracks=[System.Collections.Generic.List[object]]::new()
$script:Exts='.wav','.mp3','.m4a','.aac','.wma','.flac','.ogg','.oga','.opus','.mp4','.aif','.aiff'
$script:TempDir=$null;$script:Adding=$false
# Windows Media Foundationで任意の音声を44.1 kHz/16 bit/ステレオのPCM WAVへ変換する
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFAttributes {
    void GetItem(ref Guid key, IntPtr value);
    void GetItemType(ref Guid key, out int type);
    void CompareItem(ref Guid key, IntPtr value, out bool result);
    void Compare(IMFAttributes theirs, int matchType, out bool result);
    void GetUINT32(ref Guid key, out int value);
    void GetUINT64(ref Guid key, out long value);
    void GetDouble(ref Guid key, out double value);
    void GetGUID(ref Guid key, out Guid value);
    void GetStringLength(ref Guid key, out int length);
    void GetString(ref Guid key, IntPtr buf, int size, out int length);
    void GetAllocatedString(ref Guid key, out IntPtr buf, out int length);
    void GetBlobSize(ref Guid key, out int size);
    void GetBlob(ref Guid key, IntPtr buf, int size, out int sizeOut);
    void GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
    void GetUnknown(ref Guid key, ref Guid riid, out IntPtr obj);
    void SetItem(ref Guid key, IntPtr value);
    void DeleteItem(ref Guid key);
    void DeleteAllItems();
    void SetUINT32(ref Guid key, int value);
    void SetUINT64(ref Guid key, long value);
    void SetDouble(ref Guid key, double value);
    void SetGUID(ref Guid key, ref Guid value);
    void SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    void SetBlob(ref Guid key, IntPtr buf, int size);
    void SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unk);
    void LockStore();
    void UnlockStore();
    void GetCount(out int count);
    void GetItemByIndex(int index, out Guid key, IntPtr value);
    void CopyAllItems(IMFAttributes dest);
}

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaType { }

[ComImport, Guid("045fa593-8799-42b8-bc8d-8968c6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaBuffer {
    void Lock(out IntPtr buffer, out int maxLength, out int currentLength);
    void Unlock();
    void GetCurrentLength(out int length);
    void SetCurrentLength(int length);
    void GetMaxLength(out int length);
}

// IMFAttributes分のダミーメソッド30個を先頭に置いてvtable位置を合わせる
[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSample {
    void A00(); void A01(); void A02(); void A03(); void A04(); void A05(); void A06(); void A07(); void A08(); void A09();
    void A10(); void A11(); void A12(); void A13(); void A14(); void A15(); void A16(); void A17(); void A18(); void A19();
    void A20(); void A21(); void A22(); void A23(); void A24(); void A25(); void A26(); void A27(); void A28(); void A29();
    void GetSampleFlags(out int flags);
    void SetSampleFlags(int flags);
    void GetSampleTime(out long time);
    void SetSampleTime(long time);
    void GetSampleDuration(out long duration);
    void SetSampleDuration(long duration);
    void GetBufferCount(out int count);
    void GetBufferByIndex(int index, out IMFMediaBuffer buffer);
    void ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
}

[ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSourceReader {
    void GetStreamSelection(int stream, out bool selected);
    void SetStreamSelection(int stream, bool selected);
    void GetNativeMediaType(int stream, int index, out IMFAttributes type);
    void GetCurrentMediaType(int stream, out IMFAttributes type);
    void SetCurrentMediaType(int stream, IntPtr reserved, IMFMediaType type);
    void SetCurrentPosition(ref Guid timeFormat, IntPtr position);
    void ReadSample(int stream, int flags, out int actualStream, out int streamFlags, out long timestamp, out IMFSample sample);
}

public static class ShizukoDecoder {
    [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFStartup(int version, int flags);
    [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFShutdown();
    [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFCreateMediaType(out IMFAttributes type);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void MFCreateSourceReaderFromURL(string url, IntPtr attributes, out IMFSourceReader reader);

    const int FirstAudio = unchecked((int)0xFFFFFFFD);
    const int AllStreams = unchecked((int)0xFFFFFFFE);
    const int HeaderSize = 44;

    static void SetU32(IMFAttributes a, string key, int value) { Guid k = new Guid(key); a.SetUINT32(ref k, value); }
    static void SetGuid(IMFAttributes a, string key, string value) { Guid k = new Guid(key); Guid v = new Guid(value); a.SetGUID(ref k, ref v); }

    // 変換後のPCMデータ長（バイト）を返す。dstは44バイトヘッダ付きのWAV。
    public static Task<long> DecodeAsync(string src, string dst) {
        return Task.Run(() => Decode(src, dst));
    }

    static long Decode(string src, string dst) {
        MFStartup(0x00020070, 0);
        IMFSourceReader reader = null; IMFAttributes mt = null;
        try {
            MFCreateSourceReaderFromURL(src, IntPtr.Zero, out reader);
            reader.SetStreamSelection(AllStreams, false);
            reader.SetStreamSelection(FirstAudio, true);
            MFCreateMediaType(out mt);
            SetGuid(mt, "48eba18e-f8c9-4687-bf11-0a74c9f96a8f", "73647561-0000-0010-8000-00aa00389b71");
            SetGuid(mt, "f7e34c9a-42e8-4714-b74b-cb29d72c35e5", "00000001-0000-0010-8000-00aa00389b71");
            SetU32(mt, "37e48bf5-645e-4c5b-89de-ada9e29b696a", 2);
            SetU32(mt, "5faeeae7-0290-4c31-9e8a-c534f68d9dba", 44100);
            SetU32(mt, "f2deb57f-40fa-4764-aa33-ed4f2d1ff669", 16);
            SetU32(mt, "322de230-9eeb-43bd-ab7a-ff412251541d", 4);
            SetU32(mt, "1aab75c8-cfef-451c-ab95-ac034b8e1731", 176400);
            SetU32(mt, "c9173739-5e56-461c-b713-46fb995cb95f", 1);
            reader.SetCurrentMediaType(FirstAudio, IntPtr.Zero, (IMFMediaType)mt);

            long total = 0;
            using (FileStream fs = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None)) {
                fs.Write(new byte[HeaderSize], 0, HeaderSize);
                byte[] chunk = new byte[65536];
                while (true) {
                    int actual, flags; long ts; IMFSample sample;
                    reader.ReadSample(FirstAudio, 0, out actual, out flags, out ts, out sample);
                    if ((flags & 0x1) != 0) throw new InvalidOperationException("デコード中にエラーが発生しました。");
                    if ((flags & 0x2) != 0) { if (sample != null) Marshal.ReleaseComObject(sample); break; }
                    if (sample == null) continue;
                    IMFMediaBuffer buf = null;
                    try {
                        sample.ConvertToContiguousBuffer(out buf);
                        IntPtr p; int max, cur;
                        buf.Lock(out p, out max, out cur);
                        try {
                            for (int off = 0; off < cur; off += chunk.Length) {
                                int n = Math.Min(chunk.Length, cur - off);
                                Marshal.Copy(IntPtr.Add(p, off), chunk, 0, n);
                                fs.Write(chunk, 0, n);
                            }
                            total += cur;
                        } finally { buf.Unlock(); }
                    } finally {
                        if (buf != null) Marshal.ReleaseComObject(buf);
                        Marshal.ReleaseComObject(sample);
                    }
                }
                total -= total % 4;
                if (total <= 0) throw new InvalidOperationException("音声データがありません。");
                fs.SetLength(HeaderSize + total);
                fs.Position = 0;
                using (BinaryWriter w = new BinaryWriter(fs)) {
                    w.Write(new char[] { 'R', 'I', 'F', 'F' }); w.Write((int)(36 + total));
                    w.Write(new char[] { 'W', 'A', 'V', 'E' }); w.Write(new char[] { 'f', 'm', 't', ' ' });
                    w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(44100); w.Write(176400); w.Write((short)4); w.Write((short)16);
                    w.Write(new char[] { 'd', 'a', 't', 'a' }); w.Write((int)total);
                    w.Flush();
                }
            }
            return total;
        } finally {
            if (mt != null) Marshal.ReleaseComObject(mt);
            if (reader != null) Marshal.ReleaseComObject(reader);
            MFShutdown();
        }
    }
}
'@
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
    if ($fmt.Codec -eq 0xFFFE) {
     if ($n -lt 40) { throw 'WAV形式情報が壊れています。' }
     [void]$r.ReadBytes(8); if ([guid]::new($r.ReadBytes(16)) -eq [guid]'00000001-0000-0010-8000-00aa00389b71') { $fmt.Codec = 1 }
    }
   } elseif ($id -eq 'data') { $off = $st; $len = $n }
   $s.Position = $st + $n + ($n % 2)
  }
  if ($null -eq $fmt -or $off -lt 0) { throw 'WAVに音声データがありません。' }
  if ($fmt.Codec -ne 1 -or $fmt.Ch -ne 2 -or $fmt.Rate -ne 44100 -or $fmt.Bits -ne 16) { throw '対応形式はPCM、44.1 kHz、16 bit、ステレオです。' }
  if ($len % 4 -ne 0) { throw 'PCMデータサイズが不正です。' }
  [pscustomobject]@{ Path=$Path; DataPath=$Path; Temp=$false; Offset=$off; Length=$len; Seconds=($len / 176400.0) }
 } finally { $s.Dispose() }
}
function Remove-TempAudio($Track) { if ($Track.Temp) { try { [IO.File]::Delete($Track.DataPath) } catch {} } }
# CD形式のWAVはそのまま使い、それ以外（MP3、FLAC、別形式のWAVなど）は一時WAVへ変換する
function Read-Track([string]$Path) {
 if ([IO.Path]::GetExtension($Path) -ieq '.wav') { try { return Read-Wav $Path } catch {} }
 if ($null -eq $script:TempDir) { $script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ('Shizuko-' + [guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($script:TempDir) }
 $tmp = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N') + '.wav')
 $task = [ShizukoDecoder]::DecodeAsync($Path, $tmp)
 while (-not $task.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
 if ($task.IsFaulted) {
  try { [IO.File]::Delete($tmp) } catch {}
  throw ('読み込めませんでした（' + $task.Exception.GetBaseException().Message.Trim() + '）。この形式に対応するコーデックがWindowsにない可能性があります。')
 }
 $len = [long]$task.Result
 [pscustomobject]@{ Path=$Path; DataPath=$tmp; Temp=$true; Offset=44L; Length=$len; Seconds=($len / 176400.0) }
}
$f=[System.Windows.Forms.Form]::new();$f.Text='Shizuko - 音楽CD作成';$f.StartPosition='CenterScreen';$f.Size=[System.Drawing.Size]::new(820,600);$f.MinimumSize=[System.Drawing.Size]::new(720,510);$f.Font=[System.Drawing.Font]::new('Segoe UI',9)
$h=[System.Windows.Forms.Label]::new();$h.Text='Shizuko';$h.Font=[System.Drawing.Font]::new('Segoe UI Semibold',22);$h.Location=[System.Drawing.Point]::new(20,14);$h.AutoSize=$true;$f.Controls.Add($h)
$hint=[System.Windows.Forms.Label]::new();$hint.Text='WAV・MP3・FLACなどの音声ファイルから音楽CDを作成';$hint.Location=[System.Drawing.Point]::new(22,55);$hint.AutoSize=$true;$f.Controls.Add($hint)
$lv=[System.Windows.Forms.ListView]::new();$lv.Location=[System.Drawing.Point]::new(20,90);$lv.Size=[System.Drawing.Size]::new(765,330);$lv.Anchor='Top,Bottom,Left,Right';$lv.View='Details';$lv.FullRowSelect=$true;$lv.AllowDrop=$true
[void]$lv.Columns.Add('曲',440);[void]$lv.Columns.Add('時間',90);[void]$lv.Columns.Add('場所',220);$f.Controls.Add($lv)
$add=[System.Windows.Forms.Button]::new();$add.Text='曲を追加';$add.Location=[System.Drawing.Point]::new(20,432);$add.Size=[System.Drawing.Size]::new(100,32);$add.Anchor='Bottom,Left';$f.Controls.Add($add)
$dl=[System.Windows.Forms.Label]::new();$dl.Text='ドライブ:';$dl.Location=[System.Drawing.Point]::new(135,438);$dl.AutoSize=$true;$dl.Anchor='Bottom,Left';$f.Controls.Add($dl)
$drive=[System.Windows.Forms.ComboBox]::new();$drive.DropDownStyle='DropDownList';$drive.Location=[System.Drawing.Point]::new(200,434);$drive.Size=[System.Drawing.Size]::new(310,28);$drive.Anchor='Bottom,Left';$f.Controls.Add($drive)
$time=[System.Windows.Forms.Label]::new();$time.Text='合計 00:00 / 80:00';$time.Location=[System.Drawing.Point]::new(520,438);$time.AutoSize=$true;$time.Anchor='Bottom,Right';$f.Controls.Add($time)
$status=[System.Windows.Forms.Label]::new();$status.Text='音声ファイルを追加するか、画面にドラッグしてください。';$status.Location=[System.Drawing.Point]::new(22,523);$status.Size=[System.Drawing.Size]::new(430,28);$status.Anchor='Bottom,Left,Right';$f.Controls.Add($status)
$del=[System.Windows.Forms.Button]::new();$del.Text='削除';$del.Location=[System.Drawing.Point]::new(470,520);$del.Size=[System.Drawing.Size]::new(70,34);$del.Anchor='Bottom,Right';$f.Controls.Add($del)
$up=[System.Windows.Forms.Button]::new();$up.Text='上へ';$up.Location=[System.Drawing.Point]::new(542,520);$up.Size=[System.Drawing.Size]::new(55,34);$up.Anchor='Bottom,Right';$f.Controls.Add($up)
$down=[System.Windows.Forms.Button]::new();$down.Text='下へ';$down.Location=[System.Drawing.Point]::new(599,520);$down.Size=[System.Drawing.Size]::new(55,34);$down.Anchor='Bottom,Right';$f.Controls.Add($down)
$burn=[System.Windows.Forms.Button]::new();$burn.Text='書き込み';$burn.Location=[System.Drawing.Point]::new(657,518);$burn.Size=[System.Drawing.Size]::new(128,38);$burn.Anchor='Bottom,Right';$f.Controls.Add($burn)
function Refresh-List{$lv.BeginUpdate();$lv.Items.Clear();for($i=0;$i-lt$script:Tracks.Count;$i++){$t=$script:Tracks[$i];$x=[System.Windows.Forms.ListViewItem]::new(('{0}. {1}'-f($i+1),[IO.Path]::GetFileName($t.Path)));$s=[int][math]::Round($t.Seconds);[void]$x.SubItems.Add(('{0:D2}:{1:D2}'-f[int][math]::Floor($s/60),($s%60)));[void]$x.SubItems.Add([IO.Path]::GetDirectoryName($t.Path));[void]$lv.Items.Add($x)};$lv.EndUpdate();$sum=($script:Tracks|Measure-Object Seconds -Sum).Sum;if($null-eq$sum){$sum=0};$n=[int][math]::Ceiling($sum);$time.Text='合計 {0:D2}:{1:D2} / 80:00'-f[int][math]::Floor($n/60),($n%60);if($n-gt4800){$time.ForeColor=[Drawing.Color]::Firebrick}else{$time.ForeColor=[Drawing.SystemColors]::ControlText}}
function Add-Files([string[]]$paths){if($script:Adding){return};$script:Adding=$true;Set-Busy $true;try{$added=0;$skip=0;$dup=0;$files=foreach($p in $paths){if([IO.Directory]::Exists($p)){[IO.Directory]::GetFiles($p)|Where-Object{$script:Exts-contains[IO.Path]::GetExtension($_).ToLowerInvariant()}|Sort-Object}else{$p}};foreach($p in $files){if($script:Exts-notcontains[IO.Path]::GetExtension($p).ToLowerInvariant()){$skip++;continue};if($script:Tracks|Where-Object Path -eq $p){$dup++;continue};$status.Text='読み込み中: '+[IO.Path]::GetFileName($p);try{$script:Tracks.Add((Read-Track $p));$added++}catch{[void][System.Windows.Forms.MessageBox]::Show(('{0}: {1}'-f[IO.Path]::GetFileName($p),$_.Exception.Message),'追加できません')}};Refresh-List;$msg='{0}曲を追加しました。'-f$added;if($skip){$msg+='対応していない形式の{0}件は対象外です。'-f$skip};if($dup){$msg+='追加済みの{0}件はスキップしました。'-f$dup};$status.Text=$msg}finally{$script:Adding=$false;Set-Busy $false}}
function Load-Drives{$drive.Items.Clear();$m=$null;try{$m=New-Object -ComObject IMAPI2.MsftDiscMaster2;$bad=0;for($i=0;$i-lt$m.Count;$i++){$r=$null;try{$id=$m.Item($i);$r=New-Object -ComObject IMAPI2.MsftDiscRecorder2;$r.InitializeDiscRecorder($id);$name=@($r.VolumePathNames)|Select-Object -First 1;if([string]::IsNullOrWhiteSpace($name)){$name='光学ドライブ'};[void]$drive.Items.Add([pscustomobject]@{Id=$id;Label=('{0} ({1} {2})'-f$name,"$($r.VendorId)".Trim(),"$($r.ProductId)".Trim())})}catch{$bad++}finally{if($r){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($r)}}};$drive.DisplayMember='Label';if($drive.Items.Count){$drive.SelectedIndex=0;if($bad){$status.Text='{0}台のドライブを取得できませんでした。'-f$bad}}elseif($bad){$status.Text='使用できる光学ドライブがありません（取得失敗 {0}台）。'-f$bad}else{$status.Text='光学ドライブがありません。'}}catch{$status.Text='ドライブ取得エラー: '+$_.Exception.Message}finally{if($m){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($m)}}}
$picker=[System.Windows.Forms.OpenFileDialog]::new();$picker.Filter='音声ファイル|'+(($script:Exts|ForEach-Object{'*'+$_})-join';')+'|すべてのファイル (*.*)|*.*';$picker.Multiselect=$true
$add.Add_Click({if($picker.ShowDialog()-eq'OK'){Add-Files $picker.FileNames}})
$del.Add_Click({foreach($i in @($lv.SelectedIndices|Sort-Object -Descending)){Remove-TempAudio $script:Tracks[[int]$i];$script:Tracks.RemoveAt([int]$i)};Refresh-List})
function Move-Track([int]$d){if($lv.SelectedIndices.Count-ne1){return};$i=$lv.SelectedIndices[0];$j=$i+$d;if($j-lt0-or$j-ge$script:Tracks.Count){return};$x=$script:Tracks[$i];$script:Tracks.RemoveAt($i);$script:Tracks.Insert($j,$x);Refresh-List;$lv.Items[$j].Selected=$true}
$up.Add_Click({Move-Track -1});$down.Add_Click({Move-Track 1})
$onDragEnter={if($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)){$_.Effect='Copy'}};$onDragDrop={Add-Files $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)}
foreach($c in $f,$lv){$c.AllowDrop=$true;$c.Add_DragEnter($onDragEnter);$c.Add_DragDrop($onDragDrop)}
function Set-Busy([bool]$busy){foreach($c in $add,$del,$up,$down,$burn,$drive){$c.Enabled=!$busy};$f.AllowDrop=!$busy;$lv.AllowDrop=!$busy}
$burnJob={
 param($Tracks,$DriveId,$Sync)
 $ErrorActionPreference='Stop';$w=$null;$r=$null
 try{
  $r=New-Object -ComObject IMAPI2.MsftDiscRecorder2;$r.InitializeDiscRecorder($DriveId);$w=New-Object -ComObject IMAPI2.MsftDiscFormat2TrackAtOnce;$w.Recorder=$r;$w.ClientName='Shizuko';$Sync.Status='ディスクを準備しています…';$w.PrepareMedia()
  $needed=0L;foreach($t in $Tracks){$needed += [math]::Ceiling($t.Length/2352.0)+150};if($needed-gt$w.FreeSectorsOnMedia){throw'ディスクの空き容量が足りません。'}
  $buf=New-Object byte[] 1048576
  for($i=0;$i-lt$Tracks.Count;$i++){
   $t=$Tracks[$i];$Sync.Status='書き込み中 {0}/{1}: {2}'-f($i+1),$Tracks.Count,[IO.Path]::GetFileName($t.Path);$a=New-Object -ComObject ADODB.Stream;$src=$null
   try{$a.Type=1;$a.Open();$src=[IO.File]::OpenRead($t.DataPath);$src.Position=$t.Offset;$left=$t.Length;while($left-gt0){$n=$src.Read($buf,0,[int][math]::Min($buf.Length,$left));if($n-le0){throw'音声データの読み込みエラー。'};if($n-eq$buf.Length){$a.Write($buf)}else{$part=New-Object byte[] $n;[Array]::Copy($buf,$part,$n);$a.Write($part)};$left-=$n};$pad=(2352-$t.Length%2352)%2352;if($pad){$a.Write((New-Object byte[] $pad))};$a.Position=0;$w.AddAudioTrack($a)
   }finally{if($src){$src.Dispose()};if($a.State-eq1){$a.Close()};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($a)}
  }
  $w.ReleaseMedia()
 }catch{$Sync.Error=$_.Exception.Message;if($w){try{$w.ReleaseMedia()}catch{}}
 }finally{if($w){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($w)};if($r){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($r)};$Sync.Done=$true}
}
$script:Job=$null;$timer=[System.Windows.Forms.Timer]::new();$timer.Interval=300
$burn.Add_Click({
 $sum=($script:Tracks|Measure-Object Seconds -Sum).Sum
 if(!$script:Tracks.Count){[void][System.Windows.Forms.MessageBox]::Show('先に音声ファイルを追加してください。');return};if($sum-gt4800){[void][System.Windows.Forms.MessageBox]::Show('80分を超えています。');return};if($script:Tracks.Count-gt99){[void][System.Windows.Forms.MessageBox]::Show('CDの上限は99曲です。');return};if($null-eq$drive.SelectedItem){[void][System.Windows.Forms.MessageBox]::Show('書き込みドライブがありません。');return}
 if([System.Windows.Forms.MessageBox]::Show('空のCD-R/CD-RWを入れてください。書き込みを開始します。','確認','OKCancel','Question')-ne'OK'){return}
 $sync=[hashtable]::Synchronized(@{Status='書き込みを開始しています…';Done=$false;Error=$null})
 $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open();$ps=[powershell]::Create();$ps.Runspace=$rs
 [void]$ps.AddScript($burnJob).AddArgument($script:Tracks.ToArray()).AddArgument($drive.SelectedItem.Id).AddArgument($sync)
 Set-Busy $true;$script:Job=@{PS=$ps;Sync=$sync;Handle=$ps.BeginInvoke()};$timer.Start()
})
$timer.Add_Tick({
 $b=$script:Job;$status.Text=$b.Sync.Status;if(!$b.Sync.Done){return}
 $timer.Stop();try{[void]$b.PS.EndInvoke($b.Handle)}catch{if(!$b.Sync.Error){$b.Sync.Error=$_.Exception.Message}}finally{$b.PS.Runspace.Dispose();$b.PS.Dispose()};$script:Job=$null;Set-Busy $false
 if($b.Sync.Error){$status.Text='書き込みに失敗しました。';[void][System.Windows.Forms.MessageBox]::Show(('書き込みエラー: '+$b.Sync.Error),'エラー')}else{$status.Text='完了';[void][System.Windows.Forms.MessageBox]::Show('音楽CDの書き込みが完了しました。','Shizuko')}
})
$f.Add_FormClosing({if($script:Job){$_.Cancel=$true;[void][System.Windows.Forms.MessageBox]::Show('書き込み中は終了できません。完了までお待ちください。','Shizuko')}elseif($script:Adding){$_.Cancel=$true;[void][System.Windows.Forms.MessageBox]::Show('音声ファイルの読み込み中は終了できません。完了までお待ちください。','Shizuko')}})
$f.Add_FormClosed({if($script:TempDir){try{[IO.Directory]::Delete($script:TempDir,$true)}catch{}}})
$f.Add_Shown({Load-Drives});[void]$f.ShowDialog()
