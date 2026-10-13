# Hides or shows all desktop icons (the same as right-click desktop > View > Show desktop icons).
# Run again to bring them back. Nothing is moved or deleted.
Add-Type @'
using System; using System.Runtime.InteropServices;
public class Desk {
  [DllImport("user32.dll")] static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string c, string n);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  // the desktop's icon view lives under Progman, or under a WorkerW once a wallpaper slideshow has run
  static IntPtr View() {
    IntPtr v = FindWindowEx(FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null);
    IntPtr w = IntPtr.Zero;
    while (v == IntPtr.Zero && (w = FindWindowEx(IntPtr.Zero, w, "WorkerW", null)) != IntPtr.Zero)
      v = FindWindowEx(w, IntPtr.Zero, "SHELLDLL_DefView", null);
    return v;
  }
  public static bool Toggle() { IntPtr v = View(); if (v == IntPtr.Zero) return false; SendMessage(v, 0x0111, (IntPtr)0x7402, IntPtr.Zero); return true; }
}
'@
$before = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideIcons -ErrorAction SilentlyContinue).HideIcons
if ([Desk]::Toggle()) { if ($before -eq 1) { 'Desktop icons shown.' } else { 'Desktop icons hidden. Run CLEAN DESKTOP again to show them.' } }
else { 'Could not find the desktop - right-click the desktop, View, and untick "Show desktop icons".' }
