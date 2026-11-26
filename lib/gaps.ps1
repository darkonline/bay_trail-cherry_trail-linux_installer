# Шаг «Чего не хватает»: для каждого пробела из прогноза — взять из Windows, указать свой файл, выбрать похожее или пропустить.
# Использует функции установщика (Ask-Number, Ask-YesNo, Select-Touch, New-TouchChoice, Show-TouchChoice) и lib\fw.ps1.
# Всё найденное кладётся в cache\bundle (touch\ и firmware\ — как в /lib/firmware на планшете), выбор — строками для setup.conf.

function Save-BundleBytes([byte[]]$b, [string]$path) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    [System.IO.File]::WriteAllBytes($path, $b)
    $path
}
function Get-SafeModelName($dmi) {
    $s = ((("{0}-{1}" -f $dmi.SYS_VENDOR, $dmi.PRODUCT_NAME).ToLower()) -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $s) { $s = "tablet" }
    $s
}
# свойства тача для параметра ядра: из записи ядра (props) или из описания gsl-firmware (params)
function Format-TouchProps($kind, $entry, [string]$fwName) {
    $r = @()
    if ($kind -eq "kernel" -and $entry.props) {
        foreach ($p in $entry.props.PSObject.Properties) {
            if ($p.Name -eq "firmware-name") { continue }
            if ($p.Value -is [bool]) { if ($p.Value) { $r += $p.Name } }
            else { $r += ("{0}={1}" -f $p.Name, $p.Value) }
        }
    } elseif ($kind -eq "local") {
        if ($entry.touch_props) { $r += @(([string]$entry.touch_props -split ':') | Where-Object { $_ -and $_ -notlike "firmware-name=*" }) }
    } elseif ($entry.params) {
        $q = $entry.params
        if ($q.size_x) { $r += "touchscreen-size-x=$($q.size_x)"; $r += "touchscreen-size-y=$($q.size_y)" }
        if ($q.swapped_x_y) { $r += "touchscreen-swapped-x-y" }
        if ($q.inverted_x) { $r += "touchscreen-inverted-x" }
        if ($q.inverted_y) { $r += "touchscreen-inverted-y" }
    }
    $r += "firmware-name=$fwName"
    $r -join ":"
}
# выбрать файл из найденных
function Select-FoundFile([string[]]$files, [string]$what) {
    if (-not $files) { return $null }
    if ($files.Count -eq 1) { Write-Host ("  Найдено: " + $files[0]); return $files[0] }
    Write-Host "  Найдено несколько файлов ($what):"
    for ($i = 0; $i -lt $files.Count; $i++) { Write-Host ("  {0,3}. {1} ({2:N0} байт)" -f ($i+1), $files[$i], (Get-Item -LiteralPath $files[$i]).Length) }
    $n = Ask-Number "  Номер файла (0 — ни один)" 0 $files.Count
    if ($n -eq 0) { return $null }
    $files[$n-1]
}

# ------------------------------------------------------------------ тачскрин Silead
function New-TouchFromCandidates($cands, $ctx, [string]$bundle, [string]$origin) {
    $cands = @($cands)
    if (-not $cands) { Write-Host "  Прошивок тача Silead в этих файлах не найдено." -ForegroundColor Yellow; return $null }
    Write-Host ("  Найдено прошивок: {0}" -f $cands.Count)
    $best = 0
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $m = @(Find-TouchCatalogMatch $ctx.Touch $c.Sha1 $ctx.Local)
        $c | Add-Member -NotePropertyName Matches -NotePropertyValue $m -Force
        $mt = if ($m) { "совпадает с: " + (($m | ForEach-Object { $_.Entry.name }) -join "; ") } else { "в каталогах не встречается" }
        Write-Host ("  {0,3}. {1:N0} байт, из {2} — {3}" -f ($i+1), $c.Size, (Split-Path $c.From -Leaf), $mt)
        if ($m -and -not $cands[$best].Matches) { $best = $i }
    }
    $pick = $best
    if ($cands.Count -gt 1) {
        Write-Host ("  В драйвере бывает несколько прошивок под разные панели. Рекомендую № {0}." -f ($best+1))
        $n = Ask-Number ("  Номер прошивки (0 — рекомендованная)") 0 $cands.Count
        if ($n -gt 0) { $pick = $n - 1 }
    }
    $c = $cands[$pick]
    $fwName = "mssl1680-" + (Get-SafeModelName $ctx.Dmi) + ".fw"
    $local = Save-BundleBytes $c.Bytes (Join-Path $bundle ("touch\" + $fwName))
    # остальные — на планшете их можно будет попробовать
    $k = 0
    for ($i = 0; $i -lt $cands.Count; $i++) {
        if ($i -eq $pick) { continue }
        $k++; [void](Save-BundleBytes $cands[$i].Bytes (Join-Path $bundle ("touch\candidates\fw-{0}.fw" -f $k)))
    }
    $notes = @()
    $src = if ($origin -eq "windows") { "из драйвера тача Windows этого планшета" } else { "из файлов, которые вы указали" }
    $notes += "Прошивка взята $src ($(Split-Path $c.From -Leaf))."
    $calib = "yes"
    $props = "firmware-name=$fwName"
    $model = "{0} {1}" -f $ctx.Dmi.SYS_VENDOR, $ctx.Dmi.PRODUCT_NAME
    $m = @($c.Matches)
    if ($m) {
        # одна прошивка встречается в разных планшетах с разными осями (Myria MY8307 и Digma CITI 1804) —
        # рекомендуем запись, в названии которой есть производитель из DMI, иначе запись ядра
        $vendor = ([string]$ctx.Dmi.SYS_VENDOR).ToLower()
        # порядок выбора: производитель из DMI + известные параметры, затем производитель, затем ядро, затем первая
        $hasP = { param($x) ((Format-TouchProps $x.Kind $x.Entry "x") -replace ':?firmware-name=x$', '') -ne "" }
        $isV = { param($x) $vendor -and ([string]$x.Entry.name).ToLower().Contains($vendor) }
        $rec = -1
        for ($i = 0; $i -lt $m.Count -and $rec -lt 0; $i++) { if ((& $isV $m[$i]) -and (& $hasP $m[$i])) { $rec = $i } }
        for ($i = 0; $i -lt $m.Count -and $rec -lt 0; $i++) { if (& $isV $m[$i]) { $rec = $i } }
        for ($i = 0; $i -lt $m.Count -and $rec -lt 0; $i++) { if ($m[$i].Kind -eq "kernel") { $rec = $i } }
        if ($rec -lt 0) { $rec = 0 }
        $h = $m[$rec]
        if ($m.Count -gt 1) {
            Write-Host "  Эта прошивка стоит в нескольких моделях, и размеры/оси тача у них могут отличаться:"
            $kindText = @{ kernel = "ядро"; community = "gsl-firmware"; pending = "PR, не принят"; local = "база установщика" }
            for ($i = 0; $i -lt $m.Count; $i++) {
                $pp = (Format-TouchProps $m[$i].Kind $m[$i].Entry "x") -replace ':?firmware-name=x$', ''
                $kt = $kindText[$m[$i].Kind]
                if (@($m[$i].AlsoIn).Count) { $kt += "; также: " + (@($m[$i].AlsoIn) -join ", ") }
                Write-Host ("  {0,3}. {1} [{2}]: {3}" -f ($i+1), $m[$i].Entry.name, $kt, $(if ($pp) { $pp } else { "параметров нет" }))
            }
            Write-Host ("  Рекомендую № {0}." -f ($rec+1))
            $n = Ask-Number "  Чьи параметры взять (0 — рекомендованные)" 0 $m.Count
            if ($n -gt 0) { $h = $m[$n-1] }
        }
        $props = Format-TouchProps $h.Kind $h.Entry $fwName
        if ($props -eq "firmware-name=$fwName") {
            $notes += "Прошивка байт в байт совпадает с «$($h.Entry.name)», но размер и оси тача там неизвестны — замерим на планшете."
            $calib = "yes"
        } else {
            $notes += "Прошивка байт в байт совпадает с «$($h.Entry.name)» — размер и оси тача взяты оттуда."
            $notes += "Одна прошивка бывает в планшетах с разной ориентацией тача — проверим касанием на планшете."
            $calib = "check"
        }
    } else {
        $notes += "Такой прошивки нет ни в ядре, ни в gsl-firmware, ни в базе установщика: размер тача замерим на планшете (калибровка по углам)."
    }
    if ($k) { $notes += "Ещё прошивок из драйвера: $k — сохранены в touch\candidates на случай, если эта не подойдёт." }
    [pscustomobject]@{ Kind = $origin; Model = $model; Source = $origin + "-driver"; FwName = $fwName; FwUrl = ""; FwSha1 = $c.Sha1
                       FwSize = $c.Size; Props = $props; Notes = $notes; FwLocal = $local; Calibrate = $calib; Own = (-not $m); FromFile = $c.From }
}
# модель из своей базы (catalog\local.json): прошивка лежит в catalog\local-fw
$LocalStatusText = @{ "driver-pack" = "из пачки драйверов"; "from-device" = "данные с планшета"; "verified" = "проверено на планшете"; "submitted" = "проверено, отправлено в gsl-firmware/ядро" }
function New-TouchFromLocal($entry, $ctx, [string]$bundle) {
    $fw = @($entry.touch_firmware)[0]
    if (-not $fw) { return $null }
    $src = Join-Path $ctx.CatalogDir ($fw.file -replace '/', '\')
    if (-not (Test-Path $src)) { Write-Host "  Нет файла прошивки $src" -ForegroundColor Yellow; return $null }
    $fwName = "mssl1680-" + (Get-SafeModelName $ctx.Dmi) + ".fw"
    $local = Save-BundleBytes ([System.IO.File]::ReadAllBytes($src)) (Join-Path $bundle ("touch\" + $fwName))
    $props = Format-TouchProps "local" $entry $fwName
    $notes = @("Из базы установщика: $($entry.name) — $($LocalStatusText[[string]$entry.status]).")
    $calib = "check"
    if ($props -eq "firmware-name=$fwName") { $calib = "yes"; $notes += "Размер и оси тача для этой модели неизвестны — замерим на планшете." }
    if ($fw.known) { $notes += "Та же прошивка: $($fw.known)." }
    [pscustomobject]@{ Kind = "local"; Model = $entry.name; Source = "local-db"; FwName = $fwName; FwUrl = ""; FwSha1 = $fw.git_blob_sha1
                       FwSize = [int]$fw.size; Props = $props; Notes = $notes; FwLocal = $local; Calibrate = $calib; Own = $false; FromFile = "" }
}
function Resolve-TouchGap($row, $ctx, [string]$bundle, [string]$cacheRoot) {
    $part = @($ctx.Hw.parts | Where-Object { $_.id -eq $row.PartId })[0]
    # модель есть в своей базе по DMI — это лучший вариант
    $lh = $null
    if ($ctx.Local) { $lh = @($ctx.Local.devices | Where-Object { $_.match -and $_.touch_firmware -and (Test-DmiMatch $_ $ctx.Dmi) })[0] }
    while ($true) {
        Write-Host ""
        if ($lh) { Write-Host ("   4. Взять из базы установщика: {0} (рекомендуется)" -f $lh.name) }
        Write-Host ("   1. Взять прошивку из драйвера тача Windows этого планшета" + $(if (-not $lh) { " (рекомендуется)" } else { "" }))
        Write-Host "   2. Указать файл, папку или архив с драйвером тача (например, скачанный с форума)"
        Write-Host "   3. Выбрать похожую модель из списка (ядро, gsl-firmware, открытые PR)"
        Write-Host "   0. Пропустить — без прошивки тач в Linux работать не будет"
        $n = Ask-Number "  Выбор" 0 $(if ($lh) { 4 } else { 3 })
        $t = $null
        switch ($n) {
            0 { return $null }
            1 {
                Write-Host "  Ищу драйвер тача в хранилище драйверов Windows..." -ForegroundColor DarkGray
                $dirs = @(Find-DriverFolders @($part.ids) $ctx.DriverRoot)
                if (-not $dirs) { Write-Host "  Драйвер тача Silead в Windows не найден." -ForegroundColor Yellow; continue }
                $files = Find-FilesIn $dirs @("*.sys", "*.fw")
                $t = New-TouchFromCandidates (Get-SileadCandidates $files) $ctx $bundle "windows"
                if ($t) { $t | Add-Member -NotePropertyName DriverFiles -NotePropertyValue @(Find-FilesIn $dirs @("*.sys", "*.inf", "*.fw")) -Force }
            }
            2 {
                $src = Expand-UserSource (Read-UserSource "драйвер тача: SileadTouch.sys, SileadTouch.fw или архив с ними") $cacheRoot
                if (-not $src) { continue }
                $files = Find-FilesIn @($src) @("*.sys", "*.fw", "*.fw_*")
                $t = New-TouchFromCandidates (Get-SileadCandidates $files) $ctx $bundle "user"
                if ($t) { $t | Add-Member -NotePropertyName DriverFiles -NotePropertyValue @(Find-FilesIn @($src) @("*.sys", "*.inf", "*.fw")) -Force; $t.Own = $true }
            }
            3 { $t = Select-Touch; if ($t -and -not $t.PSObject.Properties["Calibrate"]) { $t | Add-Member -NotePropertyName Calibrate -NotePropertyValue "check" -Force } }
            4 { $t = New-TouchFromLocal $lh $ctx $bundle }
        }
        if ($t) {
            Show-TouchChoice $t
            if (Ask-YesNo "  Взять это?") { return $t }
        }
    }
}

# ------------------------------------------------------------------ файлы прошивок (Wi-Fi, Bluetooth, Chipone, недостающие)
function Resolve-FileGap($row, $ctx, [string]$bundle, [string]$cacheRoot) {
    $part = @($ctx.Hw.parts | Where-Object { $_.id -eq $row.PartId })[0]
    $dev = @($row.Devices)[0]
    $ids = @(); $masks = @(); $dest = @(); $what = ""; $note = ""
    switch -Wildcard ($row.Gap) {
        "wifi-nvram" {
            $ids = @("VID_02D0", "VID_04B4", "VID_02d0", "VID_04b4"); $masks = @("*.txt", "*.nvm"); $what = "файл настроек Wi-Fi (NVRAM, .txt)"
            $bin = ""
            if ($dev -and $part.firmware_by_id -and $part.firmware_by_id.PSObject.Properties[$dev.Id]) { $bin = @($part.firmware_by_id.PSObject.Properties[$dev.Id].Value)[0].path }
            if ($bin) { $dest = @(($bin -replace '\.bin$', '.txt')) } else { $dest = @("brcm/brcmfmac-sdio.txt"); $note = "Чип Wi-Fi не опознан — имя файла на планшете придётся поправить." }
        }
        "bt-hcd" { $ids = @("BCM2E"); $masks = @("*.hcd"); $what = "прошивка Bluetooth Broadcom (.hcd)"; $dest = @("brcm/BCM.hcd") }
        "windows-fw" {
            $ids = @($part.ids); $masks = @("*.bin", "*.fw"); $what = "прошивка тача Chipone"
            $sub = if ($dev -and $dev.Subsys) { $dev.Subsys } else { "unknown" }
            $dest = @("chipone/icn8505-$sub.fw"); $note = "Формат файла из драйвера Windows для этого тача заранее не проверен."
        }
        "firmware:*" { $p = $row.Gap.Substring(9); $masks = @((Split-Path $p -Leaf) + "*"); $what = "файл $p"; $dest = @($p) }
    }
    while ($true) {
        Write-Host ""
        if ($ids) { Write-Host "   1. Взять из драйвера Windows этого планшета (рекомендуется)" }
        Write-Host "   2. Указать файл, папку или архив ($what)"
        Write-Host "   0. Пропустить"
        $n = Ask-Number "  Выбор" 0 2
        if ($n -eq 0) { return $null }
        $files = @(); $origin = ""
        if ($n -eq 1) {
            if (-not $ids) { continue }
            Write-Host "  Ищу в хранилище драйверов Windows..." -ForegroundColor DarkGray
            $dirs = @(Find-DriverFolders $ids $ctx.DriverRoot)
            if (-not $dirs) { Write-Host "  Подходящий драйвер в Windows не найден." -ForegroundColor Yellow; continue }
            $files = @(Find-FilesIn $dirs $masks | Where-Object { (Split-Path $_ -Leaf) -notmatch '(?i)readme|license|licence|eula|copying|release' })
            $origin = "windows"
        } else {
            $src = Expand-UserSource (Read-UserSource $what) $cacheRoot
            if (-not $src) { continue }
            $files = @(Find-FilesIn @($src) $masks); $origin = "user"
        }
        $f = Select-FoundFile $files $what
        if (-not $f) { Write-Host "  Подходящих файлов нет." -ForegroundColor Yellow; continue }
        $b = [System.IO.File]::ReadAllBytes($f)
        $saved = @()
        $dests = @($dest)
        # Bluetooth: ядро сначала ищет файл по имени чипа (BCM43430A1.hcd), в конце — BCM.hcd; кладём под оба имени
        if ($row.Gap -eq "bt-hcd" -and (Split-Path $f -Leaf) -match '^(BCM[0-9A-Za-z]+?)(_|\.hcd)') { $dests += "brcm/$($Matches[1]).hcd" }
        foreach ($d in ($dests | Sort-Object -Unique)) { $saved += Save-BundleBytes $b (Join-Path $bundle ("firmware\" + ($d -replace '/', '\'))) }
        Write-Host ("  Сохранено как: " + (($dests | Sort-Object -Unique) -join ", ")) -ForegroundColor Green
        if ($note) { Write-Host ("  - " + $note) -ForegroundColor DarkGray }
        return [pscustomobject]@{ Dest = @($dests | Sort-Object -Unique); From = $f; Origin = $origin; Saved = $saved }
    }
}

# ------------------------------------------------------------------ все пробелы
function Resolve-Gaps($ctx, $rows, [string]$bundle, [string]$cacheRoot) {
    $res = [pscustomobject]@{ Touch = $null; TouchHandled = $false; Conf = @(); Files = @(); Own = $false; Extra = @() }
    $done = @{}
    $notFound = @()
    foreach ($r in @($rows | Where-Object { $_.Gap })) {
        if ($done.ContainsKey($r.Gap)) { continue }
        $done[$r.Gap] = $true
        if ($r.Gap -like "not-found-*") { $notFound += $r; continue }
        Write-Host ""
        Write-Host ("  ── {0}: {1}" -f $ForecastCats[$r.Category], $r.Part) -ForegroundColor Cyan
        foreach ($n in @($r.Notes | Select-Object -First 2)) { Write-Host ("     " + $n) -ForegroundColor DarkGray }
        switch -Wildcard ($r.Gap) {
            "touch-*" {
                $res.TouchHandled = $true
                $t = Resolve-TouchGap $r $ctx $bundle $cacheRoot
                $res.Touch = $t
                if ($t -and $t.FromFile) { $res.Files += @($t.DriverFiles) }
                if ($t -and $t.Own) { $res.Own = $true }
            }
            "oot:bluetooth" { $res.Conf += ("FIX_BT_RTL_MODULE=" + $(if (Ask-YesNo "  Собрать модуль Bluetooth на планшете после установки (~2 мин)?") { "yes" } else { "no" })) }
            "oot:isp-pm"    { $res.Conf += ("FIX_ISP_PM=" + $(if (Ask-YesNo "  Собрать модуль, выключающий ISP, чтобы работал глубокий сон?") { "yes" } else { "no" })) }
            "early-modules" { $res.Conf += ("FIX_EARLY_MODULES=" + $(if (Ask-YesNo "  Загружать модули подсветки рано (рекомендуется)?") { "yes" } else { "no" })) }
            "panel-orientation" {
                Write-Host "   1. Определить поворот на планшете при первом запуске (рекомендуется)"
                Write-Host "   2. Повернуть: правая сторона вверх (right_side_up)"
                Write-Host "   3. Повернуть: левая сторона вверх (left_side_up)"
                Write-Host "   0. Не поворачивать"
                $v = @("none", "ask", "right_side_up", "left_side_up")[(Ask-Number "  Выбор" 0 3)]
                $res.Conf += "PANEL_ORIENTATION=$v"
            }
            "accel-matrix" { $res.Conf += ("ACCEL_CALIBRATE=" + $(if (Ask-YesNo "  Откалибровать датчик поворота на планшете?") { "yes" } else { "no" })) }
            default {
                $g = Resolve-FileGap $r $ctx $bundle $cacheRoot
                if ($g) {
                    $res.Extra += @($g.Dest)
                    $res.Files += $g.From
                    $res.Own = $true
                }
            }
        }
    }
    if ($res.Extra) { $res.Conf += ("FW_EXTRA='" + (($res.Extra | Sort-Object -Unique) -join " ") + "'") }
    if ($notFound) {
        Write-Host ""
        Write-Host "  Не найдено в Windows (если деталь на самом деле есть — пришлите архив в конце, это поможет):" -ForegroundColor DarkGray
        foreach ($r in $notFound) { Write-Host ("   - " + $r.Notes[0]) -ForegroundColor DarkGray }
    }
    $res
}
