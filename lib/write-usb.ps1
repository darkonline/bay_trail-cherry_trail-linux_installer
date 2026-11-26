# Запись образа на флешку. Запускается установщиком с правами администратора (окно UAC).
# Задание берётся из JSON-файла (-Job), результат пишется в JSON-файл (поле result_file задания).
#   disk_number, disk_model, disk_size — какой диск выбран в установщике (перепроверяется здесь);
#   image — путь к .img.xz; image_size — размер распакованного образа; bundle — папка с setup.conf и файлами;
#   verify — проверить запись чтением; target_file — ПРОВЕРКА: писать в обычный файл вместо диска (без прав администратора).
# Порядок: проверки -> подтверждение -> очистка диска -> запись (первый 1 МиБ с таблицей разделов — последним,
# чтобы Windows не подключила разделы посреди записи) -> проверка чтением -> копирование bundle на раздел pmOS_boot.
param([Parameter(Mandatory = $true)][string]$JobFile)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = "SilentlyContinue"

$job = Get-Content -Raw -Encoding UTF8 $JobFile | ConvertFrom-Json
$result = [ordered]@{ ok = $false; stage = "start"; error = ""; bytes = 0; sha256 = ""; verified = $null; copied = @(); boot_letter = "" }
function Save-Result { [System.IO.File]::WriteAllText($job.result_file, ($result | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false))) }
function Fail([string]$msg) {
    $result.error = $msg; Save-Result
    Write-Host ""; Write-Host ("  ОШИБКА: " + $msg) -ForegroundColor Red
    if (-not $job.target_file) { Read-Host "  Enter — закрыть окно" | Out-Null }
    exit 1
}
Add-Type -TypeDefinition @"
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class BtRawDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    public static FileStream Open(string path, bool write) {
        uint access = write ? 0xC0000000u : 0x80000000u;          // GENERIC_READ | GENERIC_WRITE
        uint flags = write ? 0x80000000u : 0u;                      // FILE_FLAG_WRITE_THROUGH
        SafeFileHandle h = CreateFile(path, access, 3u, IntPtr.Zero, 3u, flags, IntPtr.Zero);  // FILE_SHARE_READ|WRITE, OPEN_EXISTING
        if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new FileStream(h, write ? FileAccess.ReadWrite : FileAccess.Read, 1, false);
    }
}
"@

$test = [bool]$job.target_file
$size = [int64]$job.image_size
$sector = 512
Write-Host ""
Write-Host "  Запись образа на флешку" -ForegroundColor Cyan
Write-Host ("  Образ: " + $job.image)

# ------------------------------------------------------------------ проверки
$result.stage = "checks"
$7z = @("C:\Program Files\7-Zip\7z.exe", "C:\Program Files (x86)\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $7z) { Fail "Не найден 7-Zip — он нужен для распаковки образа." }
if (-not (Test-Path $job.image)) { Fail "Нет файла образа: $($job.image)" }
if ($size -le 0 -or $size % $sector -ne 0) { Fail "Размер распакованного образа неизвестен или не кратен $sector байт: $size" }
if ($test) {
    $target = [string]$job.target_file
    Write-Host ("  ПРОВЕРКА: запись в файл " + $target + " (диск не трогается)") -ForegroundColor Yellow
} else {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Fail "Нет прав администратора." }
    $d = Get-Disk -Number ([int]$job.disk_number) -ErrorAction SilentlyContinue
    if (-not $d) { Fail "Диск $($job.disk_number) не найден — флешку вынули?" }
    if ($d.BusType -ne "USB") { Fail "Диск $($d.Number) — не USB ($($d.BusType)). Запись отменена." }
    if ($d.IsBoot -or $d.IsSystem) { Fail "Диск $($d.Number) — системный. Запись отменена." }
    if ([int64]$d.Size -ne [int64]$job.disk_size -or [string]$d.FriendlyName -ne [string]$job.disk_model) {
        Fail "Диск $($d.Number) уже не тот, что был выбран ($($d.FriendlyName), $([math]::Round($d.Size/1GB,1)) ГБ). Запись отменена."
    }
    if ([int64]$d.Size -lt $size) { Fail ("Флешка мала: {0:N1} ГБ, а образ {1:N1} ГБ." -f ($d.Size/1GB), ($size/1GB)) }
    # образ, установщик и папка задания не должны лежать на этой флешке
    foreach ($p in @($job.image, $job.bundle, $PSScriptRoot)) {
        $q = [System.IO.Path]::GetPathRoot((Resolve-Path $p).Path).TrimEnd('\').TrimEnd(':')
        $part = Get-Partition -DriveLetter $q -ErrorAction SilentlyContinue
        if ($part -and $part.DiskNumber -eq $d.Number) { Fail "Файлы установщика ($p) лежат на этой же флешке. Перенесите установщик на другой диск." }
    }
    $sector = [int]$d.LogicalSectorSize
    if ($sector -le 0) { $sector = 512 }
    $target = "\\.\PhysicalDrive$($d.Number)"
    Write-Host ("  Флешка: диск {0}, {1}, {2:N1} ГБ" -f $d.Number, $d.FriendlyName, ($d.Size/1GB)) -ForegroundColor Yellow
    Write-Host "  ВСЕ ДАННЫЕ НА НЕЙ БУДУТ УДАЛЕНЫ." -ForegroundColor Yellow
    $a = Read-Host ("  Последнее подтверждение: введите номер диска ({0})" -f $d.Number)
    if ($a.Trim() -ne [string]$d.Number) { $result.error = "Отменено пользователем"; Save-Result; Write-Host "  Отменено, на диск ничего не записано."; Read-Host "  Enter — закрыть окно" | Out-Null; exit 2 }

    # ---------------------------------------------------------- очистка диска
    $result.stage = "clean"
    Write-Host "  Очищаю флешку (удаляю разделы)..."
    $cleaned = $false
    try { Clear-Disk -Number $d.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop; $cleaned = $true } catch { Write-Host ("  Clear-Disk не сработал: " + $_.Exception.Message + " — пробую diskpart") -ForegroundColor DarkGray }
    if (-not $cleaned) {
        $dp = Join-Path (Split-Path $JobFile -Parent) "diskpart-clean.txt"
        Set-Content -Path $dp -Value @("select disk $($d.Number)", "clean") -Encoding ASCII
        & diskpart.exe /s $dp | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "Не удалось очистить флешку (diskpart, код $LASTEXITCODE)." }
    }
}

# ------------------------------------------------------------------ запись
$result.stage = "write"
$head = [int64](1MB)
$buf = New-Object byte[] (4MB)
$first = New-Object byte[] $head
$sha = [System.Security.Cryptography.SHA256]::Create()
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $7z
$psi.Arguments = 'x -so -bsp0 -bso0 "' + $job.image + '"'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$in = $proc.StandardOutput.BaseStream
if ($test) { $out = New-Object System.IO.FileStream($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite) }
else { try { $out = [BtRawDisk]::Open($target, $true) } catch { Fail ("Не удалось открыть флешку для записи: " + $_.Exception.Message) } }
function Read-Full($stream, [byte[]]$b, [int]$count) {
    $n = 0
    while ($n -lt $count) { $r = $stream.Read($b, $n, $count - $n); if ($r -le 0) { break }; $n += $r }
    $n
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$total = [int64]0
try {
    # первый 1 МиБ (таблица разделов) — запоминаем и пишем в самом конце
    $n = Read-Full $in $first ([int]$head)
    if ($n -ne $head) { throw "Образ короче 1 МиБ ($n байт)." }
    [void]$sha.TransformBlock($first, 0, $n, $null, 0)
    $total = $n
    [void]$out.Seek($head, [System.IO.SeekOrigin]::Begin)
    $lastShow = 0
    while ($true) {
        $n = Read-Full $in $buf $buf.Length
        if ($n -le 0) { break }
        [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
        $w = $n
        if ($n % $sector -ne 0) { $w = $n + ($sector - $n % $sector); [Array]::Clear($buf, $n, $w - $n) }
        $out.Write($buf, 0, $w)
        $total += $n
        if ($sw.ElapsedMilliseconds - $lastShow -gt 1000) {
            $lastShow = $sw.ElapsedMilliseconds
            $mbs = ($total / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds)
            Write-Host ("`r  Записано {0,6:N0} из {1:N0} МБ ({2,3:N0}%), {3:N1} МБ/с   " -f ($total/1MB), ($size/1MB), (100*$total/$size), $mbs) -NoNewline
        }
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "7-Zip завершился с кодом $($proc.ExitCode) — образ повреждён?" }
    if ($total -ne $size) { throw "Распаковано $total байт, ожидалось $size." }
    [void]$out.Seek(0, [System.IO.SeekOrigin]::Begin)
    $out.Write($first, 0, $first.Length)
    $out.Flush()
} catch {
    try { $out.Close() } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    Fail ("Запись прервана: " + $_.Exception.Message + " Флешка сейчас не загрузочная — запишите заново.")
}
$out.Close()
$result.bytes = $total
$result.sha256 = (($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join "")
Write-Host ("`r  Записано {0:N0} МБ за {1:N0} с.                                   " -f ($total/1MB), $sw.Elapsed.TotalSeconds)

# ------------------------------------------------------------------ проверка чтением
if ($job.verify) {
    $result.stage = "verify"
    Write-Host "  Проверяю запись чтением..."
    $rs = if ($test) { [System.IO.File]::OpenRead($target) } else { [BtRawDisk]::Open($target, $false) }
    $sha2 = [System.Security.Cryptography.SHA256]::Create()
    $left = $size; $sw.Restart(); $lastShow = 0
    while ($left -gt 0) {
        $want = [int][math]::Min([int64]$buf.Length, $left)
        $rd = $want
        if ($rd % $sector -ne 0) { $rd += $sector - $rd % $sector }
        $n = Read-Full $rs $buf $rd
        if ($n -lt $want) { $rs.Close(); Fail "Чтение с флешки оборвалось — флешка неисправна?" }
        [void]$sha2.TransformBlock($buf, 0, $want, $null, 0)
        $left -= $want
        if ($sw.ElapsedMilliseconds - $lastShow -gt 1000) { $lastShow = $sw.ElapsedMilliseconds; Write-Host ("`r  Проверено {0,3:N0}%   " -f (100 * ($size - $left) / $size)) -NoNewline }
    }
    [void]$sha2.TransformFinalBlock($buf, 0, 0)
    $rs.Close()
    $h2 = (($sha2.Hash | ForEach-Object { $_.ToString("x2") }) -join "")
    $result.verified = ($h2 -eq $result.sha256)
    if (-not $result.verified) { Fail "Записанное не совпадает с образом (SHA-256 $h2 вместо $($result.sha256)). Флешка неисправна или её вынули." }
    Write-Host "`r  Проверка чтением: записано без ошибок.            " -ForegroundColor Green
}

# ------------------------------------------------------------------ файлы установщика на раздел pmOS_boot
if (-not $test) {
    $result.stage = "copy"
    Write-Host "  Копирую настройки установщика на загрузочный раздел флешки..."
    Update-Disk -Number $d.Number -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $p1 = $null
    for ($i = 0; $i -lt 10 -and -not $p1; $i++) {
        $p1 = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.PartitionNumber -eq 1 }
        if (-not $p1) { Start-Sleep -Seconds 1; Update-Disk -Number $d.Number -ErrorAction SilentlyContinue }
    }
    if (-not $p1) { Fail "Windows не видит разделы на записанной флешке. Образ записан; настройки скопировать не удалось." }
    $letter = [string]$p1.DriveLetter
    $assigned = $false
    if (-not $letter -or $letter -eq "`0") {
        $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
        $letter = @("Z","Y","X","W","V","U","T","S","R","Q","P") | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        # раздел ESP: Windows сама букву не даёт; diskpart умеет
        $dp = Join-Path (Split-Path $JobFile -Parent) "diskpart-assign.txt"
        Set-Content -Path $dp -Value @("select disk $($d.Number)", "select partition 1", "assign letter=$letter") -Encoding ASCII
        & diskpart.exe /s $dp | Out-Null
        $assigned = $true
    }
    $root = "${letter}:\"
    for ($i = 0; $i -lt 20 -and -not (Test-Path $root); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path $root)) { Fail "Не удалось открыть загрузочный раздел флешки (буква $letter). Образ записан; настройки скопировать не удалось." }
    $dst = Join-Path $root "bt-installer"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Recurse -Force (Join-Path $job.bundle "*") $dst
    foreach ($f in (Get-ChildItem -Recurse -File $job.bundle)) {
        $rel = $f.FullName.Substring((Get-Item $job.bundle).FullName.Length).TrimStart('\')
        $c = Join-Path $dst $rel
        if (-not (Test-Path $c) -or (Get-FileHash $c).Hash -ne (Get-FileHash $f.FullName).Hash) { Fail "Файл $rel скопировался с ошибкой." }
        $result.copied += $rel
    }
    $result.boot_letter = $letter
    if ($assigned) {
        Set-Content -Path $dp -Value @("select disk $($d.Number)", "select partition 1", "remove letter=$letter") -Encoding ASCII
        & diskpart.exe /s $dp | Out-Null
    }
    Write-Host ("  Скопировано файлов: {0} (папка bt-installer на разделе pmOS_boot)." -f $result.copied.Count) -ForegroundColor Green
}

$result.stage = "done"
$result.ok = $true
Save-Result
Write-Host ""
Write-Host "  Готово. Флешку можно извлечь (значок «Безопасное извлечение»)." -ForegroundColor Green
if (-not $test) { Read-Host "  Enter — закрыть окно" | Out-Null }
exit 0
