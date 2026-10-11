$sig = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class PebAny {
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool ReadProcessMemory(IntPtr h, IntPtr baseAddr, byte[] buf, int size, out IntPtr read);
  [DllImport("ntdll.dll")]
  public static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] info, int len, out int ret);
  [DllImport("kernel32.dll")]
  public static extern bool CloseHandle(IntPtr h);

  public static byte[] R(IntPtr h, long addr, int size) {
    byte[] b = new byte[size];
    IntPtr read;
    if (!ReadProcessMemory(h, (IntPtr)addr, b, size, out read)) return null;
    return b;
  }

  public static string[] Dump(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) throw new Exception("OpenProcess failed err=" + Marshal.GetLastWin32Error());
    try {
      byte[] info = new byte[48];
      int ret;
      if (NtQueryInformationProcess(h, 0, info, 48, out ret) != 0) throw new Exception("NtQuery failed");
      long peb = BitConverter.ToInt64(info, 8);
      byte[] pp = R(h, peb + 0x20, 8);
      long procParams = BitConverter.ToInt64(pp, 0);
      byte[] ep = R(h, procParams + 0x80, 8);
      long envPtr = BitConverter.ToInt64(ep, 0);
      byte[] env = R(h, envPtr, 262144);
      if (env == null) throw new Exception("read env failed");
      string all = Encoding.Unicode.GetString(env);
      string[] parts = all.Split('\0');
      List<string> list = new List<string>();
      foreach (string p in parts) {
        if (p.Length == 0) { if (list.Count > 0) break; else continue; }
        list.Add(p);
      }
      return list.ToArray();
    } finally { CloseHandle(h); }
  }
}
"@
Add-Type -TypeDefinition $sig -ErrorAction Stop

Write-Host "=== codex.exe / ChatGPT 进程的关键环境变量 ==="
foreach ($proc in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(codex|ChatGPT)$' })) {
  try {
    $vars = [PebAny]::Dump($proc.Id)
    $hit = $vars | Where-Object { $_ -match '^(DEEPSEEK_API_KEY|CODEX_DEEPSEEK_API_KEY|CODEX_HOME|CODEX_CLI_PATH)=' }
    if ($hit) {
      Write-Host ("--- " + $proc.ProcessName + " PID " + $proc.Id + " ---")
      foreach ($h in $hit) {
        $i = $h.IndexOf('=')
        $n = $h.Substring(0, $i); $v = $h.Substring($i + 1)
        if ($n -match 'KEY' -and $v.Length -gt 16) { $v = $v.Substring(0, 10) + '****' + $v.Substring($v.Length - 4) }
        Write-Host ("    " + $n + " = " + $v)
      }
    }
  } catch { }
}
