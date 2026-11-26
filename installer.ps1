# Установщик Linux для планшетов на Intel Bay Trail / Cherry Trail — прототип (вариант А).
# Установщик запускают прямо на планшете под Windows.
# Шаги: устройство -> прогноз «что заработает» -> чего не хватает -> система -> твики -> образ -> флешка -> запись.
# Запись на флешку — только после выбора диска, ввода его номера и слова СТЕРЕТЬ; сама запись идёт
# в отдельном окне с правами администратора (lib\write-usb.ps1), которое ещё раз всё проверяет.
# Запуск: installer.bat (или powershell -ExecutionPolicy Bypass -File installer.ps1)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = "SilentlyContinue"

$Root    = $PSScriptRoot
$Catalog = Join-Path $Root "catalog"
$Cache   = Join-Path $Root "cache"
# куда отправлять архивы с данными о новых устройствах — заявки (Issues) репозитория установщика
$ReportIssues = "https://github.com/darkonline/bay_trail-cherry_trail-linux_installer/issues"
New-Item -ItemType Directory -Force -Path $Cache | Out-Null
. (Join-Path $Root "lib\ui.ps1")
. (Join-Path $Root "lib\hw.ps1")
. (Join-Path $Root "lib\fw.ps1")
. (Join-Path $Root "lib\gaps.ps1")

function Read-Json([string]$name) {
    Get-Content -Raw -Encoding UTF8 (Join-Path $Catalog $name) | ConvertFrom-Json
}

# ------------------------------------------------------------------ 1. устройство
function Detect-Device($devices) {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
    $os  = Get-CimInstance Win32_OperatingSystem
    $fw = $env:firmware_type
    if (-not $fw -and (Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'ACPI_HAL\\UEFI%'")) { $fw = "UEFI" }
    $cpu64 = ($cpu.AddressWidth -eq 64) -or ($cpu.DataWidth -eq 64)
    $os64  = ($os.OSArchitecture -match "64")
    $bits = if ($fw -eq "UEFI" -and $cpu64 -and -not $os64) { "32-битный UEFI (вероятно)" }
            elseif ($fw -eq "UEFI") { "64-битный UEFI" } else { "не определено" }
    $cpuName = ($cpu.Name -replace '\s+',' ').Trim()
    $platform = "не Bay/Cherry Trail"
    if ($cpuName -match 'Z37\d\d|N2[89]\d\d|J1[89]\d\d|J2[89]\d\d') { $platform = "Bay Trail" }
    if ($cpuName -match 'Z8[2-7]\d\d|x5-Z8|x7-Z8') { $platform = "Cherry Trail" }
    $script:Platform = $platform; $script:CpuName = $cpuName
    $script:Uefi32 = ($fw -eq "UEFI" -and $cpu64 -and -not $os64)

    Write-Host ("  Производитель      : " + $cs.Manufacturer)
    Write-Host ("  Модель             : " + $cs.Model)
    Write-Host ("  Процессор          : " + $cpuName + "  (" + $platform + ")")
    Write-Host ("  Прошивка (UEFI)    : " + $bits)
    Write-Host ("  Оперативная память : {0} ГБ" -f [math]::Round($cs.TotalPhysicalMemory/1GB,1))
    # накопитель, с которого загружена Windows (на планшете — встроенная память eMMC); остальные диски — для сведения
    try {
        foreach ($dk in @(Get-Disk | Sort-Object Number)) {
            $role = if ($dk.IsBoot -or $dk.IsSystem) { "системный (Windows)" } elseif ($dk.BusType -eq "USB") { "USB" } else { "другой" }
            Write-Host ("  Накопитель {0,-7} : {1}, {2:N0} ГБ ({3}, {4})" -f $dk.Number, $dk.FriendlyName, ($dk.Size/1GB), $dk.BusType, $role)
        }
    } catch {
        foreach ($dk in @(Get-CimInstance Win32_DiskDrive | Sort-Object Index)) {
            Write-Host ("  Накопитель {0,-7} : {1}, {2:N0} ГБ ({3})" -f $dk.Index, $dk.Model, ($dk.Size/1GB), $dk.InterfaceType)
        }
    }

    foreach ($d in $devices) {
        if ($d.match.manufacturer -and $cs.Manufacturer -like ("*" + $d.match.manufacturer + "*") -and
            $cs.Model -like ("*" + $d.match.model + "*")) { return $d }
    }
    if ($platform -eq "не Bay/Cherry Trail") {
        Write-Host ""
        Write-Host "  Этот компьютер — не планшет на Bay/Cherry Trail. Установщик рассчитан на запуск" -ForegroundColor Yellow
        Write-Host "  прямо на планшете: прогноз ниже будет неточным." -ForegroundColor Yellow
    }
    return $null
}

# ------------------------------------------------------------------ 1б. тачскрин (catalog\touch.json)
$TouchSrcText = @{
    "gsl-firmware"        = "Прошивка — готовый файл из gsl-firmware; размер и оси тача ядро знает само."
    "gsl-firmware-folder" = "Прошивка — файл из папки устройства в gsl-firmware (среди готовых для ядра его нет); размер и оси ядро знает само."
    "efi"                 = "Ядро само достаёт прошивку из UEFI планшета; скачивать ничего не нужно."
    "not-needed"          = "Тач не Silead (обычно Goodix): прошивка не нужна, ядро настроит его само."
    "missing"             = "Ядро знает модель, но прошивки нет ни в gsl-firmware, ни в UEFI — нужен драйвер тача из Windows этого планшета."
}
$TouchSrcShort = @{ "gsl-firmware" = "прошивка есть"; "gsl-firmware-folder" = "прошивка есть*"; "efi" = "прошивка из UEFI";
                    "not-needed" = "прошивка не нужна"; "missing" = "прошивки нет" }

# Get-WinDmi и Test-DmiMatch — в lib\hw.ps1
function Choose-FromList($items, [scriptblock]$fmt) {
    while ($true) {
        $q = Read-Host "  Часть названия для поиска (Enter — весь список, 0 — назад)"
        if ($q -eq "0") { return $null }
        $pat = "*" + [System.Management.Automation.WildcardPattern]::Escape($q) + "*"
        $list = @($items | Where-Object { -not $q -or $_.name -like $pat })
        if (-not $list) { Write-Host "  Ничего не найдено." -ForegroundColor Yellow; continue }
        for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  {0,3}. {1}" -f ($i+1), (& $fmt $list[$i])) }
        $n = Ask-Number "  Номер модели (0 — новый поиск)" 0 $list.Count
        if ($n -gt 0) { return $list[$n-1] }
    }
}
# бренд для группировки: производитель из описания, иначе первое слово названия, иначе папка gsl-firmware
$TouchBrandAlias = @{ "pointofview" = "Point of View"; "pov" = "Point of View"; "itworks" = "I.T.Works"; "gpelectronic" = "GP-electronic";
                      "alldocube" = "Cube"; "cube" = "Cube"; "trekstor" = "TrekStor"; "digma" = "Digma"; "onda" = "Onda"; "mpman" = "MPMan";
                      "globalspace" = "GlobalSpace"; "4good" = "4Good"; "ilife" = "iLife"; "chuwi" = "Chuwi"; "jumper" = "Jumper";
                      "teclast" = "Teclast"; "rca" = "RCA"; "irbis" = "Irbis"; "dexp" = "DEXP"; "pipo" = "PiPO"; "viglen" = "Viglen" }
function Get-TouchBrand([string]$name, [string]$manufacturer, [string]$folder) {
    $n = $name.Trim('"', ' ')
    if ($n -match '^(?i)point of view') { return "Point of View" }
    if ($n -match '^(?i)mp[ -]?man') { return "MPMan" }
    $src = $manufacturer
    if (-not $src) { $src = $n }
    $w = (($src -replace '\(.*?\)', ' ' -replace '"', '').Trim() -split '\s+')[0]
    if (-not $w -and $folder) { $w = ($folder -split '/')[1] }
    $key = ($w.ToLower() -replace '[^a-z0-9]', '')
    if ($TouchBrandAlias.ContainsKey($key)) { return $TouchBrandAlias[$key] }
    if ($w.Length -gt 1) { return $w.Substring(0,1).ToUpper() + $w.Substring(1) }
    return $w
}
function Format-TouchSize($p) {
    if ($p -and $p.size_x) { return ("{0}x{1}" -f $p.size_x, $p.size_y) }
    return "размер не указан"
}
function New-TouchChoice([string]$kind, $e) {
    # своя база: прошивка лежит в catalog\local-fw и сразу копируется в cache\bundle\touch
    if ($kind -eq "local") { return (New-TouchFromLocal $e $ctx $bundle) }
    $c = [ordered]@{ Kind = $kind; Model = [string]$e.name; Source = ""; FwName = ""; FwUrl = ""; FwSha1 = ""; FwSize = 0; Props = ""; Notes = @() }
    if ($e.firmware) { $c.FwUrl = $e.firmware.url; $c.FwSha1 = $e.firmware.git_blob_sha1; $c.FwSize = [int]$e.firmware.size }
    if ($kind -eq "kernel") {
        $c.Source = "kernel-" + $e.firmware_source
        $c.FwName = [string]$e.firmware_name
        $c.Notes += $TouchSrcText[$e.firmware_source]
        if ($e.firmware_source -eq "gsl-firmware-folder") { $c.Notes += "Формат этого файла заранее не проверен." }
        return [pscustomobject]$c
    }
    $p = $e.params
    $c.Source = $kind
    if ($e.linux_name) { $c.FwName = [string]$e.linux_name }
    else { $c.FwName = ((($e.folder -split '/')[1..2] -join '-').ToLower() -replace '[^a-z0-9.\-]', '-') + ".fw" }
    $props = @()
    if ($p -and $p.size_x) { $props += "touchscreen-size-x=$($p.size_x)"; $props += "touchscreen-size-y=$($p.size_y)" }
    if ($p -and $p.swapped_x_y) { $props += "touchscreen-swapped-x-y" }
    if ($p -and $p.inverted_x)  { $props += "touchscreen-inverted-x" }
    if ($p -and $p.inverted_y)  { $props += "touchscreen-inverted-y" }
    $props += "firmware-name=$($c.FwName)"
    $c.Props = $props -join ":"
    $c.Notes += "Ядро эту модель не знает: параметры тача будут заданы параметром ядра (как у Digma CITI 1804)."
    if (-not $p -or -not $p.size_x) { $c.Notes += "В описании нет размера тача — его придётся замерить на планшете." }
    $c.Notes += "Оси и отражения взяты из описания в gsl-firmware и могут потребовать подстройки."
    if ($e.similar_kernel) { $c.Notes += "Похоже на модель из ядра «$($e.similar_kernel)» — сначала попробуйте её (пункт 1)." }
    if ($kind -eq "community") {
        $t = [string]$e.tested
        if ($t -eq "yes") { $c.Notes += "В gsl-firmware отмечено как проверенное." }
        elseif ($t -eq "no") { $c.Notes += "В gsl-firmware отмечено как НЕ проверенное." }
        else { $c.Notes += "Отметка проверки в gsl-firmware: $t" }
    } else {
        $c.Notes += "PR #$($e.pr) от $($e.created) ещё не принят: $($e.pr_url)"
    }
    return [pscustomobject]$c
}
function Select-Touch {
    $path = Join-Path $Catalog "touch.json"
    if (-not (Test-Path $path)) {
        Write-Host "  Нет catalog\touch.json — сначала запустите tools\build-touch-catalog.ps1." -ForegroundColor Yellow
        return $null
    }
    $tc = Read-Json "touch.json"
    Write-Host ("  Каталог от {0} ({1}; {2})" -f $tc.generated, $tc.sources.kernel, $tc.sources.gsl_firmware) -ForegroundColor DarkGray
    $kernel = @($tc.kernel)
    # одна общая куча: ядро + gsl-firmware + открытые PR; повторы не убираются, у каждой строки — откуда она
    $all = @()
    foreach ($e in $kernel) {
        $all += [pscustomobject]@{ name = [string]$e.name; brand = (Get-TouchBrand ([string]$e.name) "" "");
                                   kind = "kernel"; tag = "ядро: " + $TouchSrcShort[[string]$e.firmware_source]; entry = $e }
    }
    foreach ($e in @($tc.community | Where-Object { $_.firmware })) {
        $all += [pscustomobject]@{ name = [string]$e.name; brand = (Get-TouchBrand ([string]$e.name) ([string]$e.params.manufacturer) ([string]$e.folder));
                                   kind = "community"; tag = "gsl-firmware, " + (Format-TouchSize $e.params); entry = $e }
    }
    foreach ($e in @($tc.pending | Where-Object { $_.firmware })) {
        $man = ""
        if ($e.params) { $man = [string]$e.params.manufacturer }
        $all += [pscustomobject]@{ name = [string]$e.name; brand = (Get-TouchBrand ([string]$e.name) $man ([string]$e.folder));
                                   kind = "pending"; tag = "PR #$($e.pr), не принят, " + (Format-TouchSize $e.params); entry = $e }
    }
    if ($localCatalog) {
        foreach ($e in @($localCatalog.devices | Where-Object { $_.touch_firmware })) {
            $st = $LocalStatusText[[string]$e.status]
            $sz = if ($e.touch_props) { "параметры известны" } else { "размер не указан" }
            $all += [pscustomobject]@{ name = [string]$e.name; brand = [string]$e.brand; kind = "local"; tag = "база установщика: $st, $sz"; entry = $e }
        }
    }
    # одна модель из разных источников — одна строка (см. Remove-TouchDuplicates в lib\fw.ps1)
    $all = @(Remove-TouchDuplicates $all)
    foreach ($x in $all) { if (@($x.AlsoIn).Count) { $x.tag += "; также: " + (@($x.AlsoIn) -join ", ") } }
    $all = @($all | Sort-Object brand, name)
    $dmi  = Get-WinDmi
    $auto = @($kernel | Where-Object { Test-DmiMatch $_ $dmi })
    Write-Host ("  DMI этого компьютера: {0} / {1} / плата {2} / BIOS {3}" -f $dmi.SYS_VENDOR, $dmi.PRODUCT_NAME, $dmi.BOARD_NAME, $dmi.BIOS_VERSION)
    if ($auto) { foreach ($a in $auto) { Write-Host ("  Совпадение с таблицей ядра: " + $a.name) -ForegroundColor Green } }
    else { Write-Host "  С таблицей ядра не совпадает. Если установщик запущен не на самом планшете — это нормально, выберите модель вручную." -ForegroundColor DarkGray }
    while ($true) {
        Write-Host ""
        $brands = @($all | Group-Object brand | Sort-Object Name)
        if ($auto) { Write-Host ("   0. Взять определённую модель: " + $auto[0].name) }
        Write-Host ("   1. Выбрать бренд (брендов: {0}, строк: {1})" -f $brands.Count, $all.Count)
        Write-Host  "   2. Поиск по названию среди всех моделей"
        Write-Host  "   3. Пропустить (прошивку можно будет извлечь из драйвера тача Windows этого планшета)"
        Write-Host  "      Пометки: «ядро» — модель знает ядро Linux; «gsl-firmware» — есть только в gsl-firmware;" -ForegroundColor DarkGray
        Write-Host  "      «PR» — прислано в gsl-firmware, но не принято; «база установщика» — собрано нами из пачек драйверов и с планшетов." -ForegroundColor DarkGray
        Write-Host  "      Одна модель может встречаться в нескольких местах." -ForegroundColor DarkGray
        $min = 1
        if ($auto) { $min = 0 }
        $n = Ask-Number "  Выбор" $min 3
        $item = $null
        $fmt = { param($x) "{0}  [{1}]" -f $x.name, $x.tag }
        switch ($n) {
            0 { $item = [pscustomobject]@{ kind = "kernel"; entry = $auto[0] } }
            1 {
                Write-Host ""
                for ($i = 0; $i -lt $brands.Count; $i++) {
                    $line = "{0,3}. {1} ({2})" -f ($i+1), $brands[$i].Name, $brands[$i].Count
                    if ($i % 3 -eq 2 -or $i -eq $brands.Count - 1) { Write-Host ("  " + $line) } else { Write-Host -NoNewline ("  {0,-28}" -f $line) }
                }
                $b = Ask-Number "  Номер бренда (0 — назад)" 0 $brands.Count
                if ($b -gt 0) {
                    $models = @($brands[$b-1].Group)
                    for ($i = 0; $i -lt $models.Count; $i++) { Write-Host ("  {0,3}. {1}" -f ($i+1), (& $fmt $models[$i])) }
                    $m = Ask-Number "  Номер модели (0 — назад)" 0 $models.Count
                    if ($m -gt 0) { $item = $models[$m-1] }
                }
            }
            2 { $item = Choose-FromList $all $fmt }
            3 { return $null }
        }
        if (-not $item) { continue }
        $choice = New-TouchChoice $item.kind $item.entry
        Show-TouchChoice $choice
        if (Ask-YesNo "  Взять эту модель?") { return $choice }
    }
}
# скачать прошивку и сверить с хешем git-объекта из каталога (sha1 от "blob <длина>\0" + содержимое)
function Get-TouchFirmware($c, [string]$dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $r = Invoke-WebRequest -UseBasicParsing -Uri $c.FwUrl -TimeoutSec 60
    $bytes = $r.RawContentStream.ToArray()
    $hdr = [System.Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($hdr.Length + $bytes.Length)
    [Array]::Copy($hdr, $all, $hdr.Length)
    [Array]::Copy($bytes, 0, $all, $hdr.Length, $bytes.Length)
    $h = ([System.Security.Cryptography.SHA1]::Create().ComputeHash($all) | ForEach-Object { $_.ToString("x2") }) -join ""
    if ($c.FwSha1 -and $h -ne $c.FwSha1) { throw "Прошивка тача не совпала с каталогом (git sha1 $h, ожидался $($c.FwSha1))." }
    if ($bytes.Length -eq 0 -or ($bytes.Length % 8) -ne 0) { throw "Файл прошивки тача не похож на формат драйвера ядра (длина $($bytes.Length) не кратна 8)." }
    $dst = Join-Path $dir $c.FwName
    [System.IO.File]::WriteAllBytes($dst, $bytes)
    return $dst
}

# ------------------------------------------------------------------ 4. образ
function Resolve-Image($distro) {
    $html = (Invoke-WebRequest -UseBasicParsing -Uri $distro.listing -TimeoutSec 60).Content
    $dirs = [regex]::Matches($html, 'href="(\d{8}-\d{4})/"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if (-not $dirs) { throw "На странице $($distro.listing) не найдено папок с образами." }
    $latest = $dirs[-1]
    $dirUrl = $distro.listing + $latest + "/"
    $html2 = (Invoke-WebRequest -UseBasicParsing -Uri $dirUrl -TimeoutSec 60).Content
    $file = [regex]::Matches($html2, 'href="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -like ("*" + $distro.file_suffix) } | Select-Object -First 1
    if (-not $file) { throw "В $dirUrl нет файла *$($distro.file_suffix)." }
    $url = $dirUrl + $file
    $shaRaw = (Invoke-WebRequest -UseBasicParsing -Uri ($url + ".sha256") -TimeoutSec 60).Content
    # Windows PowerShell 5.1 returns non-HTML files as bytes
    if ($shaRaw -is [byte[]]) { $shaRaw = [System.Text.Encoding]::ASCII.GetString($shaRaw) }
    $sha = ($shaRaw.Trim() -split '\s+')[0]
    if ($sha -notmatch '^[0-9a-fA-F]{64}$') { throw "Не удалось прочитать контрольную сумму из $url.sha256" }
    $size = [int64]((Invoke-WebRequest -UseBasicParsing -Method Head -Uri $url -TimeoutSec 60).Headers["Content-Length"])
    [pscustomobject]@{ Url = $url; File = $file; Sha256 = $sha.ToLower(); Size = $size; Date = $latest }
}

function Get-Image($img) {
    $dst = Join-Path $Cache $img.File
    if (Test-Path $dst) {
        Write-Host "  Образ уже скачан, проверяю контрольную сумму..."
        if ((Get-FileHash -Algorithm SHA256 $dst).Hash.ToLower() -eq $img.Sha256) {
            Write-Host "  Контрольная сумма совпадает." -ForegroundColor Green
            return $dst
        }
        Write-Host "  Не совпадает — скачаю заново." -ForegroundColor Yellow
        Remove-Item $dst
    }
    Write-Host ("  Скачиваю {0:N0} МБ в {1}" -f ($img.Size/1MB), $Cache)
    try {
        Start-BitsTransfer -Source $img.Url -Destination $dst -DisplayName "Linux image" -Description $img.File
    } catch {
        Write-Host "  BITS недоступен, скачиваю обычным способом (без индикатора)..." -ForegroundColor Yellow
        Invoke-WebRequest -UseBasicParsing -Uri $img.Url -OutFile $dst
    }
    Write-Host "  Проверяю контрольную сумму (SHA-256)..."
    $h = (Get-FileHash -Algorithm SHA256 $dst).Hash.ToLower()
    if ($h -ne $img.Sha256) {
        Remove-Item $dst
        throw "Контрольная сумма не совпала: файл повреждён или подменён. Удалён."
    }
    Write-Host "  Контрольная сумма совпадает." -ForegroundColor Green
    return $dst
}

# ------------------------------------------------------------------ 5. флешка
function Get-UsbDisks {
    $list = @()
    try {
        # диск, на котором лежит сам установщик или образ, не показываем
        $own = @()
        foreach ($p in @($Root, $Cache)) {
            $q = [System.IO.Path]::GetPathRoot((Resolve-Path $p).Path).TrimEnd('\').TrimEnd(':')
            $pt = Get-Partition -DriveLetter $q -ErrorAction SilentlyContinue
            if ($pt) { $own += $pt.DiskNumber }
        }
        $list = Get-Disk | Where-Object { $_.BusType -eq "USB" -and -not $_.IsBoot -and -not $_.IsSystem -and $own -notcontains $_.Number } |
                ForEach-Object { [pscustomobject]@{ Number = $_.Number; Model = [string]$_.FriendlyName; Size = [int64]$_.Size; SizeGB = [math]::Round($_.Size/1GB,1) } }
    } catch {
        $list = Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq "USB" } |
                ForEach-Object { [pscustomobject]@{ Number = $_.Index; Model = [string]$_.Model; Size = [int64]$_.Size; SizeGB = [math]::Round($_.Size/1GB,1) } }
    }
    return @($list)
}

# размер распакованного образа (из оглавления .xz, через 7-Zip)
function Get-ImageUncompressedSize([string]$sevenZip, [string]$path) {
    $out = & $sevenZip l -slt $path 2>$null
    foreach ($l in $out) { if ($l -match '^Size = (\d+)$') { return [int64]$Matches[1] } }
    return [int64]0
}
function Find-7Zip { @("C:\Program Files\7-Zip\7z.exe", "C:\Program Files (x86)\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }

# ================================================================== main
Clear-Host
Title "Установщик Linux для планшетов Intel Bay Trail / Cherry Trail — прототип"
Write-Host "  Ничего не записывается без вашего подтверждения: флешка стирается только на последнем шаге."
# PowerShell 5.1 отдаёт JSON-массив одним объектом — разворачиваем
$devices = @(Read-Json "devices.json" | ForEach-Object { $_ })
$distros = @(Read-Json "distros.json" | ForEach-Object { $_ })
$tweaks  = @(Read-Json "tweaks.json" | ForEach-Object { $_ })
$hwCatalog = $null
if (Test-Path (Join-Path $Catalog "hw.json")) { $hwCatalog = Read-Json "hw.json" }
$touchCatalog = $null
if (Test-Path (Join-Path $Catalog "touch.json")) { $touchCatalog = Read-Json "touch.json" }
# своя база устройств (собирается tools\build-local-catalog.ps1 из репозитория bytcht-tablet-db)
$localCatalog = $null
if (Test-Path (Join-Path $Catalog "local.json")) { $localCatalog = Read-Json "local.json" }

Title "Шаг 1. Устройство"
$auto = Detect-Device $devices
Write-Host ""
$device = $null
$generic = @($devices | Where-Object { $_.id -eq "generic" })[0]
if ($auto) {
    if (Ask-YesNo ("  Определено: {0}. Верно?" -f $auto.name)) { $device = $auto }
}
if (-not $device -and -not $auto) {
    Write-Host ("  Готовых настроек для этой модели нет: " + $generic.name) -ForegroundColor Yellow
    $device = $generic
}
if (-not $device) {
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $st = if ($devices[$i].status -eq "tested") { "проверено" } else { "экспериментально" }
        Write-Host ("  {0}. {1} [{2}]" -f ($i+1), $devices[$i].name, $st)
    }
    $device = $devices[(Ask-Number "  Номер устройства" 1 $devices.Count) - 1]
}
Write-Host ("  " + $device.notes) -ForegroundColor DarkGray

Title "Шаг 1а. Прогноз: что заработает в Linux"
$ctx = $null; $forecast = @()
if (-not $hwCatalog) {
    Write-Host "  Нет catalog\hw.json — сначала запустите tools\build-hw-catalog.ps1. Прогноз пропущен." -ForegroundColor Yellow
} else {
    Write-Host "  Сверяю устройства Windows с ядром Linux дистрибутива..." -ForegroundColor DarkGray
    Write-Host ("  Каталог от {0}; {1}" -f $hwCatalog.generated, $hwCatalog.sources.kernel_config) -ForegroundColor DarkGray
    $ctx = @{ Hw = $hwCatalog; Touch = $touchCatalog; Local = $localCatalog; CatalogDir = $Catalog; Devices = (Get-WinDevices); Dmi = (Get-WinDmi); Panel = (Get-PanelInfo)
              Platform = $script:Platform; Cpu = $script:CpuName; Uefi32 = $script:Uefi32 }
    $forecast = @(Invoke-Forecast $ctx)
    Show-Forecast $forecast
    Write-Host "  Прогноз — по таблицам ядра и systemd; на планшете результат может отличаться." -ForegroundColor DarkGray
    if ($script:Platform -notin @("Bay Trail", "Cherry Trail")) {
        if (-not (Ask-YesNo "  Это не Bay/Cherry Trail. Продолжить всё равно?")) { exit 1 }
    }
    Read-Host "  Enter — дальше" | Out-Null
}

# папка с тем, что поедет на флешку; touch\ и firmware\ собираются заново при каждом запуске
$bundle = Join-Path $Cache "bundle"
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
foreach ($sub in @("touch", "firmware")) { $sp = Join-Path $bundle $sub; if (Test-Path $sp) { Remove-Item -Recurse -Force $sp } }
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $bundle "forecast.txt")

$touch = $null
$fix = $null
$gapRows = @($forecast | Where-Object { $_.Gap -and $_.Gap -notlike "not-found-*" })
if ($device.id -eq "generic" -and $ctx -and @($forecast | Where-Object { $_.Gap }).Count -gt 0) {
    Title "Шаг 1б. Чего не хватает"
    Write-Host ("  Пунктов, которые можно закрыть сейчас: {0}. Для каждого: взять из Windows, указать свой файл или пропустить." -f $gapRows.Count)
    $fix = Resolve-Gaps $ctx $forecast $bundle $Cache
    $touch = $fix.Touch
}
if ($device.id -eq "generic" -and -not ($fix -and $fix.TouchHandled)) {
    Title "Шаг 1в. Тачскрин"
    $touch = Select-Touch
}

Title "Шаг 2. Система"
if ($distros.Count -eq 1) {
    $distro = $distros[0]
    $st = if ($distro.tested_on -contains $device.id) { "проверено на этом устройстве" } else { "на этом устройстве не проверялось" }
    Write-Host ("  {0} [{1}]" -f $distro.name, $st)
} else {
    for ($i = 0; $i -lt $distros.Count; $i++) {
        $st = if ($distros[$i].tested_on -contains $device.id) { "проверено на этом устройстве" } else { "экспериментально" }
        Write-Host ("  {0}. {1} [{2}]" -f ($i+1), $distros[$i].name, $st)
    }
    $distro = $distros[(Ask-Number "  Номер дистрибутива" 1 $distros.Count) - 1]
}

Title "Шаг 3. Настройки (твики)"
$avail = @($tweaks | Where-Object {
    ($_.devices -contains $device.id) -and
    ((-not $_.families) -or ($_.families -contains $distro.family)) -and
    ((-not $_.uis) -or ($_.uis -contains $distro.id))
})
$on = @{}
foreach ($t in $avail) { $on[$t.id] = [bool]$t.default }
while ($true) {
    Write-Host ""
    for ($i = 0; $i -lt $avail.Count; $i++) {
        $t = $avail[$i]
        $box = if ($on[$t.id]) { "[x]" } else { "[ ]" }
        $req = if ($t.required) { " (обязательно)" } else { "" }
        Write-Host ("  {0,2}. {1} {2}{3}" -f ($i+1), $box, $t.name, $req)
    }
    if ($avail.Count -eq 0) { Write-Host "  Для этого сочетания готовых настроек пока нет." -ForegroundColor Yellow; break }
    $a = Read-Host "  Номер — включить/выключить, Enter — дальше"
    if (-not $a) { break }
    $n = 0
    if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $avail.Count) {
        $t = $avail[$n-1]
        if ($t.required) { Write-Host "  Эту настройку выключить нельзя." -ForegroundColor Yellow }
        else { $on[$t.id] = -not $on[$t.id] }
    }
}

Title "Шаг 4. Образ"
Write-Host "  Ищу последний образ..."
$img = Resolve-Image $distro
Write-Host ("  Образ   : {0}" -f $img.File)
Write-Host ("  Сборка  : {0}" -f $img.Date)
Write-Host ("  Размер  : {0:N0} МБ (сжатый), SHA-256 с сервера: {1}" -f ($img.Size/1MB), $img.Sha256.Substring(0,16) + "...")
$imgPath = $null
if (Ask-YesNo "  Скачать сейчас?") { $imgPath = Get-Image $img }
else { Write-Host "  Пропущено: дальше будет только план." -ForegroundColor Yellow }

# настройки для планшета: этот файл будет лежать на флешке рядом с нашими скриптами
$bundle = Join-Path $Cache "bundle"
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
$conf = @("# Выбор установщика, $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "DEVICE=$($device.id)", "DISTRO=$($distro.id)")
foreach ($t in $avail) { $conf += ("TWEAK_{0}={1}" -f ($t.id -replace '-','_').ToUpper(), $(if ($on[$t.id]) { "yes" } else { "no" })) }
$touchFile = $null
if ($touch) {
    $conf += ("TOUCH_MODEL='{0}'" -f ($touch.Model -replace "'", ""))
    $conf += "TOUCH_SOURCE=$($touch.Source)"
    $conf += "TOUCH_FW_NAME=$($touch.FwName)"
    $conf += "TOUCH_FW_GIT_SHA1=$($touch.FwSha1)"
    $conf += "TOUCH_PROPS=$($touch.Props)"
    $cal = "check"
    if ($touch.PSObject.Properties["Calibrate"] -and $touch.Calibrate) { $cal = $touch.Calibrate }
    $conf += "TOUCH_CALIBRATE=$cal"
    if ($touch.PSObject.Properties["FwLocal"] -and $touch.FwLocal) {
        $touchFile = $touch.FwLocal
        $nc = @(Get-ChildItem -ErrorAction SilentlyContinue (Join-Path $bundle "touch\candidates") -Filter *.fw).Count
        if ($nc) { $conf += "TOUCH_FW_CANDIDATES=$nc" }
    } elseif ($touch.FwUrl) {
        try { $touchFile = Get-TouchFirmware $touch (Join-Path $bundle "touch") }
        catch { Write-Host ("  Прошивку тача скачать не удалось: " + $_.Exception.Message) -ForegroundColor Yellow }
    }
}
if ($fix) { $conf += @($fix.Conf) }
# UTF-8 без BOM и с переводами строк LF: файл читает sh на планшете
[System.IO.File]::WriteAllText((Join-Path $bundle "setup.conf"), (($conf -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
if ($forecast) {
    [System.IO.File]::WriteAllText((Join-Path $bundle "forecast.txt"), (((Format-ForecastText $forecast) -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

Title "Шаг 5. Флешка"
$7z = Find-7Zip
$imgSize = [int64]0
if ($imgPath -and $7z) { $imgSize = Get-ImageUncompressedSize $7z $imgPath }
if ($imgSize -gt 0) { Write-Host ("  Распакованный образ займёт {0:N1} ГБ — нужна флешка не меньше." -f ($imgSize/1GB)) }
$target = $null
while ($true) {
    $usb = Get-UsbDisks
    if ($usb.Count -eq 0) {
        Write-Host "  USB-флешек не найдено (системные диски и диск с установщиком не показываются)." -ForegroundColor Yellow
        if (Ask-YesNo "  Вставьте флешку. Поискать ещё раз?") { continue } else { break }
    }
    for ($i = 0; $i -lt $usb.Count; $i++) {
        $small = if ($imgSize -gt 0 -and $usb[$i].Size -lt $imgSize) { "  — мала для образа" } else { "" }
        Write-Host ("  {0}. Диск {1}: {2}, {3} ГБ{4}" -f ($i+1), $usb[$i].Number, $usb[$i].Model, $usb[$i].SizeGB, $small)
    }
    $n = Ask-Number "  Номер флешки (0 — обновить список)" 0 $usb.Count
    if ($n -eq 0) { continue }
    $target = $usb[$n-1]
    if ($imgSize -gt 0 -and $target.Size -lt $imgSize) { Write-Host "  Эта флешка мала для образа." -ForegroundColor Yellow; $target = $null; continue }
    break
}

Title "Шаг 6. Запись на флешку"
Write-Host ("  Устройство : {0}" -f $device.name)
if ($device.id -eq "generic") {
    if ($touch) {
        Write-Host ("  Тачскрин   : {0}" -f $touch.Model)
        if ($touchFile -and -not $touch.FwUrl) { Write-Host ("               прошивка: {0}" -f $touchFile) }
        elseif ($touchFile) { Write-Host ("               прошивка скачана и проверена: {0}" -f $touchFile) }
        elseif ($touch.FwUrl) { Write-Host "               прошивка НЕ скачана" -ForegroundColor Yellow }
        else { Write-Host "               скачивать прошивку не нужно" }
    } else { Write-Host "  Тачскрин   : не выбран" }
}
Write-Host ("  Система    : {0}" -f $distro.name)
Write-Host ("  Образ      : {0}" -f $(if ($imgPath) { $imgPath } else { $img.Url + "  (не скачан)" }))
if ($target) { Write-Host ("  Флешка     : диск {0}, {1}, {2} ГБ — БУДЕТ ПОЛНОСТЬЮ СТЁРТА" -f $target.Number, $target.Model, $target.SizeGB) -ForegroundColor Yellow }
else { Write-Host "  Флешка     : не выбрана" }
Write-Host ("  7-Zip      : {0}" -f $(if ($7z) { $7z } else { "НЕ НАЙДЕН — нужен для распаковки образа" }))
Write-Host ""
Write-Host "  Настройки (cache\bundle\setup.conf) лягут в папку bt-installer на загрузочном разделе флешки:"
Get-Content -Encoding UTF8 (Join-Path $bundle "setup.conf") | ForEach-Object { Write-Host ("    " + $_) }
Write-Host ""
$written = $null
$why = @()
if (-not $imgPath) { $why += "образ не скачан (шаг 4)" }
if (-not $target) { $why += "флешка не выбрана" }
if (-not $7z) { $why += "не установлен 7-Zip (https://www.7-zip.org)" }
if ($imgPath -and $7z -and $imgSize -le 0) { $why += "не удалось узнать размер распакованного образа" }
if ($why) {
    Write-Host ("  Записать сейчас нельзя: " + ($why -join "; ") + ".") -ForegroundColor Yellow
    if (-not $7z -and (Ask-YesNo "  Открыть сайт 7-Zip в браузере?")) { Start-Process "https://www.7-zip.org/" }
} elseif (Ask-YesNo "  Записать образ на эту флешку сейчас?") {
    Write-Host ""
    Write-Host ("  Все файлы на диске {0} ({1}, {2} ГБ) будут удалены без возможности восстановления." -f $target.Number, $target.Model, $target.SizeGB) -ForegroundColor Yellow
    $ok = $true
    $a = [string](Read-Host ("  Подтверждение 1 из 2: введите номер диска ({0})" -f $target.Number))
    if ($a.Trim() -ne [string]$target.Number) { $ok = $false }
    if ($ok) {
        $a = [string](Read-Host "  Подтверждение 2 из 2: введите слово СТЕРЕТЬ")
        if ($a.Trim().ToUpper() -notin @("СТЕРЕТЬ", "ERASE")) { $ok = $false }
    }
    if (-not $ok) { Write-Host "  Отменено: на флешку ничего не записано." -ForegroundColor Yellow }
    else {
        $verify = Ask-YesNo "  Проверить запись чтением (рекомендуется; дольше примерно вдвое)?"
        $jobDir = Join-Path $Cache "write-job"
        New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
        $jobFile = Join-Path $jobDir "job.json"; $resFile = Join-Path $jobDir "result.json"
        Remove-Item -Force -ErrorAction SilentlyContinue $resFile
        $job = [ordered]@{ disk_number = $target.Number; disk_model = $target.Model; disk_size = $target.Size; image = $imgPath; image_size = $imgSize
                           bundle = $bundle; verify = $verify; result_file = $resFile; target_file = "" }
        [System.IO.File]::WriteAllText($jobFile, ($job | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        $args1 = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Root "lib\write-usb.ps1") + '" -JobFile "' + $jobFile + '"'
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Host "  Запись идёт в отдельном окне с правами администратора — Windows спросит разрешение." -ForegroundColor DarkGray
        try {
            if ($isAdmin) { Start-Process powershell.exe -ArgumentList $args1 -Wait -NoNewWindow }
            else { Start-Process powershell.exe -ArgumentList $args1 -Verb RunAs -Wait }
        } catch { Write-Host ("  Окно записи не запустилось: " + $_.Exception.Message) -ForegroundColor Yellow }
        if (Test-Path $resFile) {
            $written = Get-Content -Raw -Encoding UTF8 $resFile | ConvertFrom-Json
            if ($written.ok) {
                Write-Host ("  Флешка записана: {0:N0} МБ, SHA-256 распакованного образа {1}..." -f ($written.bytes/1MB), $written.sha256.Substring(0,16)) -ForegroundColor Green
                if ($written.verified) { Write-Host "  Проверка чтением пройдена." -ForegroundColor Green }
                Write-Host ("  На загрузочный раздел скопировано файлов: {0} (папка bt-installer)." -f @($written.copied).Count)
            } else {
                Write-Host ("  Запись не выполнена (этап {0}): {1}" -f $written.stage, $written.error) -ForegroundColor Yellow
            }
        } else { Write-Host "  Окно записи закрылось без результата: на флешку, скорее всего, ничего не записано." -ForegroundColor Yellow }
    }
}
Write-Host ""

# архив для разработчиков: если модель не из списка или в прогнозе есть пробелы
$gaps = @($forecast | Where-Object { $_.Level -in @("setup", "fail", "unknown") })
$ownData = ($fix -and $fix.Own)
if ($ctx -and ($device.id -eq "generic" -or $gaps -or $ownData)) {
    Title "Помочь проекту"
    Write-Host ("  Для этого планшета есть пункты без готового решения: {0}." -f $gaps.Count)
    if ($ownData) { Write-Host "  Вы добавили файлы, которых нет в каталогах установщика: они тоже попадут в архив." -ForegroundColor Yellow }
    Write-Host "  Можно собрать архив с данными о планшете (без серийных номеров) и отправить его разработчикам —"
    Write-Host "  так следующая версия установщика будет знать вашу модель. Ничего устанавливать не нужно."
    if (Ask-YesNo "  Собрать архив?") {
        $extra = @()
        if ($fix) { $extra += @($fix.Files) }
        if ($touchFile) { $extra += $touchFile }
        $zip = New-ReportPackage $Root $ctx $forecast (Join-Path $bundle "setup.conf") $extra $ReportIssues
        Write-Host ""
        Write-Host ("  Архив готов: " + $zip) -ForegroundColor Green
        Write-Host "  Отправьте его заявкой (Issue) в репозитории установщика на GitHub:" -ForegroundColor Green
        Write-Host ("    " + $ReportIssues + "/new") -ForegroundColor Green
        Write-Host "  Нужен аккаунт GitHub; архив прикрепляется перетаскиванием в поле описания. Заявки на GitHub видны всем."
        Write-Host ("  Что внутри архива — в файле " + (Join-Path (Split-Path $zip -Parent) "ПРОЧТИТЕ.txt"))
        if (Ask-YesNo "  Открыть папку с архивом?") { Start-Process explorer.exe -ArgumentList ('/select,"' + $zip + '"') }
        if (Ask-YesNo "  Открыть в браузере страницу новой заявки (заголовок с моделью уже будет заполнен)?") {
            Start-Process (Get-ReportIssueUrl $ReportIssues $ctx.Dmi)
        }
    }
}
Write-Host ""
if ($written -and $written.ok) {
    Write-Host "  Готово. Вставьте флешку в планшет и загрузитесь с неё (меню загрузки — обычно F7 или Esc при включении)." -ForegroundColor Green
    Write-Host "  Скрипт на планшете, который применит настройки из bt-installer, — следующий этап разработки." -ForegroundColor DarkGray
} else {
    Write-Host "  Готово. Флешка не записана." -ForegroundColor Green
}
