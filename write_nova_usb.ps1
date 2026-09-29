# ============================================================
#  Write Nova OS boot sector to a USB stick (sector 0 / MBR)
#  SAFETY-GUARDED: refuses anything that isn't a small USB stick.
#  Run elevated.  Pass the disk number as the only argument.
# ============================================================
param(
  [Parameter(Mandatory=$true)][int]$DiskNumber,
  [string]$Image = "C:\Users\Hunter_admin\Desktop\NovaKernel\nova.img"
)

$bin = $Image                                                # boot sector + kernel
try {
  if (-not (Test-Path $bin)) { throw "$bin not found - build it first" }
  Write-Output "Image: $bin"
  $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

  # ---- HARD SAFETY GUARD ----
  if ($disk.BusType -ne 'USB')       { throw "ABORT: disk $DiskNumber BusType=$($disk.BusType), not USB" }
  if ($disk.Size -gt 64GB)           { throw "ABORT: disk $DiskNumber is $([math]::Round($disk.Size/1GB))GB, too big to be the stick" }
  Write-Output "Target: $($disk.FriendlyName)  $([math]::Round($disk.Size/1GB,1))GB  serial=$($disk.SerialNumber)"

  # release Windows' hold on the disk
  Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
  Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
  Set-Disk -Number $DiskNumber -IsOffline $true  -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2

  $bytes = [System.IO.File]::ReadAllBytes($bin)     # boot sector + kernel image
  if ($bytes.Length % 512 -ne 0) {                  # sector-align (raw device needs whole sectors)
    $pad = 512 - ($bytes.Length % 512)
    $bytes += (New-Object byte[] $pad)
  }
  $dst = New-Object System.IO.FileStream("\\.\PhysicalDrive$DiskNumber",[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
  $dst.Write($bytes,0,$bytes.Length)
  $dst.Flush(); $dst.Close()
  Write-Output "Wrote $($bytes.Length) bytes (boot sector + kernel) to disk $DiskNumber."

  Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
  Write-Output "DONE - USB now boots Nova OS on a legacy/CSM BIOS."
} catch {
  Write-Output "FAILED: $($_.Exception.Message)"
  try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue } catch {}
}
