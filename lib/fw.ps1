# Прошивки и файлы драйверов: извлечение из драйверов Windows и из того, что дал пользователь.
# Только чтение: файлы драйверов и архивов не запускаются, из них лишь читаются байты.
# Подключается через: . (Join-Path $Root "lib\fw.ps1")

# хеш git-объекта (sha1 от "blob <длина>\0" + содержимое) — так файлы хранятся в каталогах gsl-firmware
function Get-GitBlobSha1([byte[]]$bytes) {
    $hdr = [System.Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($hdr.Length + $bytes.Length)
    [Array]::Copy($hdr, $all, $hdr.Length)
    [Array]::Copy($bytes, 0, $all, $hdr.Length, $bytes.Length)
    (([System.Security.Cryptography.SHA1]::Create().ComputeHash($all)) | ForEach-Object { $_.ToString("x2") }) -join ""
}

# ------------------------------------------------------------------ Silead
# Порт tools/scanwindrv из onitake/gsl-firmware: страница прошивки — запись (0xF0, номер страницы < 256)
# и 32 записи (индекс 0, 4 ... 0x7C, данные), всё 32-битное little-endian. Подряд идущие страницы — одна прошивка.
# Условие «осталось не меньше 129*8 байт» взято из оригинала без изменений, чтобы результат совпадал байт в байт.
function Test-SileadPage([byte[]]$b, [int]$o) {
    if ([BitConverter]::ToUInt32($b, $o) -ne 0xF0) { return $false }
    if (([BitConverter]::ToUInt32($b, $o + 4) -band 0xFFFFFF00) -ne 0) { return $false }
    for ($k = 0; $k -lt 32; $k++) {
        if ([BitConverter]::ToUInt32($b, $o + 8 + $k * 8) -ne ($k * 4)) { return $false }
    }
    return $true
}
function Find-SileadFirmware([byte[]]$b) {
    $res = @()
    $off = 0
    while ($off + 8 -le $b.Length) {
        $off = [Array]::IndexOf($b, [byte]0xF0, $off)
        if ($off -lt 0 -or $off + 8 -gt $b.Length) { break }
        if ([BitConverter]::ToUInt32($b, $off) -eq 0xF0 -and ([BitConverter]::ToUInt32($b, $off + 4) -band 0xFFFFFF00) -eq 0) {
            $size = 0
            while ($off + $size + 129 * 8 -le $b.Length -and (Test-SileadPage $b ($off + $size))) { $size += 33 * 8 }
            if ($size -gt 8) {
                $fw = New-Object byte[] $size
                [Array]::Copy($b, $off, $fw, 0, $size)
                $res += ,$fw
                $off += $size
                continue
            }
        }
        $off++
    }
    $res
}
# Порт tools/unscramble: SileadTouch.fw — текст, «зашифрованный» XOR 0x88; пары {адрес, данные} из TS_CFG_DATA
function ConvertFrom-SileadScrambled([byte[]]$b) {
    $plain = New-Object byte[] $b.Length
    for ($i = 0; $i -lt $b.Length; $i++) { $plain[$i] = $b[$i] -bxor 0x88 }
    $text = [System.Text.Encoding]::ASCII.GetString($plain)
    $ms = New-Object System.IO.MemoryStream
    $cfg = $false
    foreach ($line in ($text -split "`n")) {
        if ($cfg -and $line -match '};') { $cfg = $false }
        if ($line -match 'TS_CFG_DATA') { $cfg = $true }
        if ($cfg) {
            $l = ($line -replace '\s', '').ToLower()
            if ($l -match '\{0x([0-9a-f]+),0x([0-9a-f]+)\},') {
                $ms.Write([BitConverter]::GetBytes([uint32][Convert]::ToUInt32($Matches[1], 16)), 0, 4)
                $ms.Write([BitConverter]::GetBytes([uint32][Convert]::ToUInt32($Matches[2], 16)), 0, 4)
            }
        }
    }
    , $ms.ToArray()
}
# все прошивки тача из файлов: *.sys — поиск страниц, SileadTouch.fw/silead_ts.fw — расшифровка, *.fw в формате ядра — как есть
function Get-SileadCandidates([string[]]$files) {
    $out = @()
    foreach ($f in $files) {
        $b = [System.IO.File]::ReadAllBytes($f)
        $leaf = Split-Path $f -Leaf
        $found = @()
        if ($leaf -match '\.sys$') { $found = @(Find-SileadFirmware $b) }
        elseif ($leaf -match '^sileadtouch.*\.fw$') { $x = ConvertFrom-SileadScrambled $b; if ($x.Length -gt 0) { $found = @(, $x) } }
        elseif ($leaf -match '\.fw(_\d+)?$' -and $b.Length -gt 0 -and $b.Length % 8 -eq 0 -and $leaf -notmatch '^silead_ts\.fw$') {
            if (@(Find-SileadFirmware $b).Count -gt 0) { $found = @(, $b) }
        }
        $n = 0
        foreach ($fw in $found) {
            $n++
            $out += [pscustomobject]@{ Bytes = $fw; Size = $fw.Length; Sha1 = (Get-GitBlobSha1 $fw); From = $f; Index = $n }
        }
    }
    # одинаковые прошивки из разных файлов — одна
    $seen = @{}; $uniq = @()
    foreach ($c in $out) { if (-not $seen.ContainsKey($c.Sha1)) { $seen[$c.Sha1] = $true; $uniq += $c } }
    $uniq
}
# ключ модели для поиска повторов: «Digma CITI 1804 (CS1069EW), board J210Z» и «Digma CITI 1804 (CS1069EW)» -> digmaciti1804
function Get-TouchModelKey([string]$name) {
    ((($name.ToLower()) -replace '\(.*?\)', '' -replace ',.*$', '') -replace '[^a-z0-9]', '')
}
# Одна модель из разных источников — одна строка. Касается только записей своей базы (local):
#   local против PR (то же название или ссылка на этот PR в links) — остаётся local;
#   local против ядра (то же название) — остаётся ядро. Записи ядра между собой не схлопываются.
# Элементы — объекты с полями Kind и Entry; оставшимся добавляется AlsoIn (откуда ещё та же модель).
function Remove-TouchDuplicates($items) {
    $items = @($items)
    $locals = @($items | Where-Object { $_.Kind -eq "local" })
    if (-not $locals) { return $items }
    $drop = @{}
    $also = @{}
    foreach ($l in $locals) {
        $lk = Get-TouchModelKey ([string]$l.Entry.name)
        $prs = @(@($l.Entry.links) | ForEach-Object { if ([string]$_ -match 'gsl-firmware/pull/(\d+)') { [int]$Matches[1] } })
        foreach ($o in $items) {
            if ([object]::ReferenceEquals($o, $l)) { continue }
            $same = ((Get-TouchModelKey ([string]$o.Entry.name)) -eq $lk)
            if ($o.Kind -eq "pending" -and ($same -or ($prs -contains [int]$o.Entry.pr))) {
                $drop[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($o)] = $true
                $also[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($l)] += @("PR #$($o.Entry.pr)")
            } elseif ($o.Kind -eq "kernel" -and $same) {
                $drop[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($l)] = $true
                $also[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($o)] += @("база установщика")
            }
        }
    }
    $out = @()
    foreach ($x in $items) {
        $h = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($x)
        if ($drop.ContainsKey($h)) { continue }
        $a = @(); if ($also.ContainsKey($h)) { $a = @($also[$h] | Sort-Object -Unique) }
        $x | Add-Member -NotePropertyName AlsoIn -NotePropertyValue $a -Force
        $out += $x
    }
    $out
}
# совпадение прошивки с каталогом тачей: ядро + gsl-firmware + открытые PR (+ своя база)
function Find-TouchCatalogMatch($touchCat, [string]$sha1, $localCat = $null) {
    $hits = @()
    # своя база (catalog\local.json): name, touch_props, status
    if ($localCat) {
        foreach ($d in @($localCat.devices)) {
            if (@($d.touch_firmware | Where-Object { $_.git_blob_sha1 -eq $sha1 }).Count) { $hits += [pscustomobject]@{ Kind = "local"; Entry = $d } }
        }
    }
    foreach ($e in @($touchCat.kernel)) { if ($e.firmware -and $e.firmware.git_blob_sha1 -eq $sha1) { $hits += [pscustomobject]@{ Kind = "kernel"; Entry = $e } } }
    foreach ($e in @($touchCat.community)) { if ($e.firmware -and $e.firmware.git_blob_sha1 -eq $sha1) { $hits += [pscustomobject]@{ Kind = "community"; Entry = $e } } }
    foreach ($e in @($touchCat.pending)) { if ($e.firmware -and $e.firmware.git_blob_sha1 -eq $sha1) { $hits += [pscustomobject]@{ Kind = "pending"; Entry = $e } } }
    Remove-TouchDuplicates $hits
}

# ------------------------------------------------------------------ драйверы Windows
# папки DriverStore, в INF которых упоминается один из идентификаторов (MSSL1680, VID_02D0, BCM2E...)
function Find-DriverFolders([string[]]$ids, [string]$root = "") {
    if (-not $root) { $root = Join-Path $env:WINDIR "System32\DriverStore\FileRepository" }
    if (-not (Test-Path $root)) { return @() }
    $pat = ($ids | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $infs = Get-ChildItem -Path $root -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue
    @($infs | Where-Object { Select-String -Path $_.FullName -Pattern $pat -Quiet -ErrorAction SilentlyContinue } |
      ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
}
# файлы по маскам в папках (рекурсивно), не больше 20 МБ
function Find-FilesIn([string[]]$folders, [string[]]$masks) {
    $r = @()
    foreach ($d in $folders) {
        foreach ($m in $masks) { $r += Get-ChildItem -Path $d -Recurse -Filter $m -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 20MB } }
    }
    @($r | Sort-Object FullName -Unique | ForEach-Object { $_.FullName })
}

# ------------------------------------------------------------------ то, что дал пользователь
# Путь к файлу, папке или архиву. Архив распаковывается в cache\user-src\<номер> (ничего из него не запускается).
# Возвращает папку, в которой искать, или $null.
function Expand-UserSource([string]$path, [string]$cacheRoot) {
    if (-not $path) { return $null }
    $path = $path.Trim().Trim('"')
    $exists = $false
    try { $exists = Test-Path -LiteralPath $path } catch { $exists = $false }
    if (-not $exists) { Write-Host "  Нет такого файла или папки: $path" -ForegroundColor Yellow; return $null }
    if ((Get-Item -LiteralPath $path).PSIsContainer) { return $path }
    $dst = Join-Path $cacheRoot ("user-src\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    $7z = @("C:\Program Files\7-Zip\7z.exe", "C:\Program Files (x86)\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    try {
        if ($ext -eq ".zip") { Expand-Archive -LiteralPath $path -DestinationPath $dst -Force }
        elseif ($ext -eq ".cab") { & expand.exe -F:* $path $dst | Out-Null }
        elseif ($ext -in @(".7z", ".rar", ".exe", ".msi", ".tar", ".gz", ".xz")) {
            if (-not $7z) { Write-Host "  Для архива $ext нужен 7-Zip (не найден). Распакуйте архив сами и укажите папку." -ForegroundColor Yellow; return $null }
            & $7z x -y ("-o" + $dst) $path | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "  7-Zip не смог распаковать файл (код $LASTEXITCODE)." -ForegroundColor Yellow }
        } else {
            Copy-Item -LiteralPath $path $dst
        }
    } catch { Write-Host ("  Не удалось распаковать: " + $_.Exception.Message) -ForegroundColor Yellow; return $null }
    return $dst
}
# спросить путь; пустой ответ — окно выбора файла
function Read-UserSource([string]$what) {
    Write-Host "  Укажите файл, папку или архив ($what)."
    $p = Read-Host "  Путь (Enter — выбрать файл в окне, 0 — отмена)"
    if ($p -eq "0") { return $null }
    if (-not $p) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = $what
            $dlg.Filter = "Все файлы (*.*)|*.*"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $p = $dlg.FileName }
        } catch { Write-Host "  Окно выбора не открылось — введите путь вручную." -ForegroundColor Yellow }
    }
    if (-not $p) { return $null }
    return $p
}
