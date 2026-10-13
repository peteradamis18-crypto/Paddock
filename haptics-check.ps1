# Waits (up to 60 min) until you're on track in iRacing, then logs for 60 s whether HaptiConnect (bk-connect)
# is sending signal to each audio device, and how strong. Result: haptics-check.log
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $d 'haptics-check.log'
function W($m) { Add-Content -LiteralPath $log ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Diagnostics;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDE3 {}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMMDE3 { [PreserveSig] int EnumAudioEndpoints(int a, int b, out IMMDC3 c); }
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMMDC3 { [PreserveSig] int GetCount(out int n); [PreserveSig] int Item(int i, out IMMD3 d); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMMD3 { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); [PreserveSig] int OpenPropertyStore(int a, out IntPtr s); [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); }
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IASM3 { [PreserveSig] int A(IntPtr a,int b,out IntPtr c); [PreserveSig] int B(IntPtr a,int b,out IntPtr c); [PreserveSig] int GetSessionEnumerator(out IASE3 e); }
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IASE3 { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetSession(int i, out IASC3 s); }
[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IASC3 { [PreserveSig] int GetState(out int s); [PreserveSig] int a1(out IntPtr n); [PreserveSig] int a2(IntPtr n, IntPtr c); [PreserveSig] int a3(out IntPtr p); [PreserveSig] int a4(IntPtr p, IntPtr c); [PreserveSig] int a5(out Guid g); [PreserveSig] int a6(ref Guid g, IntPtr c); [PreserveSig] int a7(IntPtr n); [PreserveSig] int a8(IntPtr n); [PreserveSig] int a9(out IntPtr id); [PreserveSig] int a10(out IntPtr id); [PreserveSig] int GetProcessId(out uint pid); }
[ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IMeter3 { [PreserveSig] int GetPeakValue(out float v); }
public static class Sess3 { public static Dictionary<string,float> BkPeaks(){ var r=new Dictionary<string,float>(); var e=(IMMDE3)new MMDE3(); IMMDC3 c; e.EnumAudioEndpoints(0,1,out c); int n; c.GetCount(out n); Guid iid=typeof(IASM3).GUID;
 for(int i=0;i<n;i++){ IMMD3 d; c.Item(i,out d); string id; d.GetId(out id); object o; if(d.Activate(ref iid,23,IntPtr.Zero,out o)!=0) continue; IASE3 se; ((IASM3)o).GetSessionEnumerator(out se); int k; se.GetCount(out k);
  for(int j=0;j<k;j++){ IASC3 s; se.GetSession(j,out s); uint pid; s.GetProcessId(out pid); string pn=""; try{pn=Process.GetProcessById((int)pid).ProcessName;}catch{} if(pn!="bk-connect") continue; float pk=0; try{((IMeter3)s).GetPeakValue(out pk);}catch{} string key=id.Substring(id.LastIndexOf('{')); float old; r[key]= r.TryGetValue(key,out old)? Math.Max(old,pk):pk; } } return r; } }
"@
$base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
function Name($g) { $pp = Get-ItemProperty "$base\$g\Properties" -ErrorAction SilentlyContinue; "{0} ({1})" -f $pp.'{a45c254e-df1c-4efd-8020-67d146a850e0},2', $pp.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6' }
W 'waiting for you to be on track'
$deadline = (Get-Date).AddMinutes(60)
while ((Get-Date) -lt $deadline) {
  $s = & (Join-Path $d 'irdeck-cli.exe') state | Select-Object -Last 1
  if ($s -match 'onTrack=True') { break }
  Start-Sleep -Seconds 5
}
if ((Get-Date) -ge $deadline) { W 'never saw you on track'; exit 1 }
W ('on track. HaptiConnect mode: ' + ((Get-Content "$env:APPDATA\Guitammer\HaptiConnect\App.ini" | Select-String app_mode).Line))
$max = @{}
for ($i = 0; $i -lt 60; $i++) {
  $p = [Sess3]::BkPeaks()
  foreach ($k in $p.Keys) { if (-not $max.ContainsKey($k) -or $p[$k] -gt $max[$k]) { $max[$k] = $p[$k] } }
  Start-Sleep -Seconds 1
}
if ($max.Count -eq 0) { W 'HaptiConnect had NO audio stream open on any device while you drove' }
foreach ($k in $max.Keys) { W ("HaptiConnect -> {0}: strongest signal {1:0.000} (0 = silent, 1 = full)" -f (Name $k), $max[$k]) }
