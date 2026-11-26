# Общий код установщика: что Windows знает о железе и прогноз «что заработает в Linux».
# Подключается через: . (Join-Path $Root "lib\hw.ps1")
# Только чтение: ничего не меняет в системе. Серийные номера и UUID не собираются.

# ------------------------------------------------------------------ DMI
# DMI так, как его видит Windows (те же поля SMBIOS, что читает ядро)
function Get-WinDmi {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $csp  = Get-CimInstance Win32_ComputerSystemProduct
    $bb   = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $enc  = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
    # дата BIOS: берём строку WMI как есть ("20171213000000.000000+000"), без перевода в местное время,
    # иначе в часовых поясах западнее Гринвича дата съезжает на день назад
    $date = ""
    try {
        $raw = [string](Get-WmiObject Win32_BIOS).ReleaseDate
        if ($raw -match '^(\d{4})(\d{2})(\d{2})') { $date = "{0}/{1}/{2}" -f $Matches[2], $Matches[3], $Matches[1] }
    } catch { }
    $rel = ""
    if ($bios.SystemBiosMajorVersion -ne $null -and $bios.SystemBiosMajorVersion -ne 255) { $rel = "{0}.{1}" -f $bios.SystemBiosMajorVersion, $bios.SystemBiosMinorVersion }
    $ec = ""
    if ($bios.EmbeddedControllerMajorVersion -ne $null -and $bios.EmbeddedControllerMajorVersion -ne 255) { $ec = "{0}.{1}" -f $bios.EmbeddedControllerMajorVersion, $bios.EmbeddedControllerMinorVersion }
    $ct = ""
    if ($enc -and $enc.ChassisTypes) { $ct = [string]@($enc.ChassisTypes)[0] }
    [ordered]@{
        SYS_VENDOR = [string]$cs.Manufacturer; PRODUCT_NAME = [string]$cs.Model; PRODUCT_VERSION = [string]$csp.Version
        PRODUCT_SKU = [string]$cs.SystemSKUNumber; PRODUCT_FAMILY = [string]$cs.SystemFamily
        BOARD_VENDOR = [string]$bb.Manufacturer; BOARD_NAME = [string]$bb.Product; BOARD_VERSION = [string]$bb.Version
        BIOS_VENDOR = [string]$bios.Manufacturer; BIOS_VERSION = [string]$bios.SMBIOSBIOSVersion; BIOS_DATE = $date
        BIOS_RELEASE = $rel; EC_FIRMWARE_RELEASE = $ec
        CHASSIS_VENDOR = [string]$enc.Manufacturer; CHASSIS_TYPE = $ct; CHASSIS_VERSION = [string]$enc.Version
    }
}
# строка /sys/class/dmi/id/modalias, как её собирает ядро (drivers/firmware/dmi-id.c)
function Get-DmiModalias($dmi) {
    $f = @(("bvn","BIOS_VENDOR"),("bvr","BIOS_VERSION"),("bd","BIOS_DATE"),("br","BIOS_RELEASE"),("efr","EC_FIRMWARE_RELEASE"),
           ("svn","SYS_VENDOR"),("pn","PRODUCT_NAME"),("pvr","PRODUCT_VERSION"),("rvn","BOARD_VENDOR"),("rn","BOARD_NAME"),
           ("rvr","BOARD_VERSION"),("cvn","CHASSIS_VENDOR"),("ct","CHASSIS_TYPE"),("cvr","CHASSIS_VERSION"),("sku","PRODUCT_SKU"))
    $s = "dmi"
    foreach ($p in $f) {
        if (-not $dmi.Contains($p[1]) -or $dmi[$p[1]] -eq $null -or $dmi[$p[1]] -eq "") { continue }
        $v = -join (([string]$dmi[$p[1]]).ToCharArray() | Where-Object { [int]$_ -gt 32 -and [int]$_ -lt 127 -and $_ -ne ':' })
        $s += ":" + $p[0] + $v
    }
    $s + ":"
}
# как в ядре: DMI_MATCH — подстрока с учётом регистра, DMI_EXACT_MATCH — точное совпадение
function Test-DmiMatch($entry, $dmi) {
    if (-not $entry.match) { return $false }
    foreach ($m in $entry.match) {
        if (-not $dmi.Contains($m.field)) { return $false }
        $v = [string]$dmi[$m.field]
        if (-not $v) { return $false }
        if ($m.exact) { if ($v.Trim() -cne ([string]$m.value).Trim()) { return $false } }
        elseif (-not $v.Contains([string]$m.value)) { return $false }
    }
    return $true
}
# шаблон hwdb (fnmatch: * ? [..]) -> регулярное выражение
function ConvertFrom-Glob([string]$g) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $g.Length) {
        $ch = $g[$i]
        if ($ch -eq '*') { [void]$sb.Append('.*') }
        elseif ($ch -eq '?') { [void]$sb.Append('.') }
        elseif ($ch -eq '[') {
            $j = $g.IndexOf(']', $i + 1)
            if ($j -lt 0) { [void]$sb.Append('\[') }
            else { $cls = $g.Substring($i + 1, $j - $i - 1); if ($cls.StartsWith('!')) { $cls = '^' + $cls.Substring(1) }; [void]$sb.Append('[' + $cls + ']'); $i = $j }
        }
        else { [void]$sb.Append([regex]::Escape([string]$ch)) }
        $i++
    }
    '^' + $sb.ToString() + '$'
}

# ------------------------------------------------------------------ устройства Windows
# Bus: acpi | sdio | pci | usb | display; Id: MSSL1680, 024C:B723, 8086:22B8, CMN0001
function ConvertTo-HwDevice([string]$pnp, [string]$name, [string]$class, $err, [string]$hwids = "") {
    $bus = ""; $id = ""
    if ($pnp -match '^ACPI\\VEN_([0-9A-Z]+)&DEV_([0-9A-Z]+)') { $bus = "acpi"; $id = ($Matches[1] + $Matches[2]).ToUpper() }
    elseif ($pnp -match '^ACPI\\([^\\]+)') { $bus = "acpi"; $id = $Matches[1].ToUpper() }
    elseif ($pnp -match '^SD\\VID_([0-9A-F]+)&PID_([0-9A-F]{4})(\\|&)') { $bus = "sdio"; $id = ("{0:X4}:{1}" -f [Convert]::ToInt32($Matches[1], 16), $Matches[2].ToUpper()) }
    elseif ($pnp -match '^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') { $bus = "pci"; $id = ($Matches[1] + ":" + $Matches[2]).ToUpper() }
    elseif ($pnp -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { $bus = "usb"; $id = ($Matches[1] + ":" + $Matches[2]).ToUpper() }
    elseif ($pnp -match '^DISPLAY\\([^\\]+)') { $bus = "display"; $id = $Matches[1].ToUpper() }
    if (-not $bus) { return $null }
    $st = "неизвестно"
    if ($err -ne $null -and "$err" -ne "") {
        switch ([int]$err) { 0 { $st = "работает" } 22 { $st = "отключено" } 28 { $st = "нет драйвера" } default { $st = "ошибка $err" } }
    }
    # идентификатор подсистемы ACPI (_SUB), например SUBSYS_HAMP0002 — по нему ядро называет некоторые прошивки
    $sub = ""
    if ($hwids -match 'SUBSYS_([0-9A-Z]+)') { $sub = $Matches[1] }
    [pscustomobject]@{ Bus = $bus; Id = $id; Name = $name; Class = $class; Status = $st; Subsys = $sub }
}
# -FromCsv: выгрузка Get-PnpDevice/Win32_PnPEntity в CSV (Name, PNPClass, DeviceID[, ConfigManagerErrorCode]) — для проверки без планшета
function Get-WinDevices([string]$FromCsv = "") {
    $list = @()
    if ($FromCsv) {
        foreach ($r in (Import-Csv -Path $FromCsv -Encoding UTF8)) {
            $d = ConvertTo-HwDevice ([string]$r.DeviceID) ([string]$r.Name) ([string]$r.PNPClass) $r.ConfigManagerErrorCode ([string]$r.HardwareID)
            if ($d) { $list += $d }
        }
    } else {
        foreach ($e in (Get-CimInstance Win32_PnPEntity)) {
            $d = ConvertTo-HwDevice ([string]$e.PNPDeviceID) ([string]$e.Name) ([string]$e.PNPClass) $e.ConfigManagerErrorCode (@($e.HardwareID) -join "; ")
            if ($d) { $list += $d }
        }
    }
    # одно устройство может быть в нескольких экземплярах (I2C, GPIO) — оставляем по одному
    @($list | Sort-Object Bus, Id, Status -Unique)
}
# экран: родное разрешение панели (предпочтительный режим EDID) и текущее в Windows
function Get-PanelInfo {
    $r = [ordered]@{ NativeWidth = 0; NativeHeight = 0; CurrentWidth = 0; CurrentHeight = 0; Source = "" }
    try {
        $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop | Select-Object -First 1
        if ($m) {
            $mode = @($m.MonitorSourceModes)[[int]$m.PreferredMonitorSourceModeIndex]
            $r.NativeWidth = [int]$mode.HorizontalActivePixels; $r.NativeHeight = [int]$mode.VerticalActivePixels
            $r.Source = "EDID"
        }
    } catch { }
    $v = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
    if ($v) { $r.CurrentWidth = [int]$v.CurrentHorizontalResolution; $r.CurrentHeight = [int]$v.CurrentVerticalResolution }
    $r
}

# ------------------------------------------------------------------ прогноз
$ForecastLevels = [ordered]@{
    ok      = @{ Text = "заработает";      Color = "Green" }
    likely  = @{ Text = "скорее всего";    Color = "DarkGreen" }
    setup   = @{ Text = "нужна настройка"; Color = "Yellow" }
    fail    = @{ Text = "не заработает";   Color = "Red" }
    unknown = @{ Text = "неизвестно";      Color = "DarkGray" }
}
$ForecastCats = [ordered]@{ screen = "Экран"; touch = "Тачскрин"; audio = "Звук"; wifi = "Wi-Fi"; bluetooth = "Bluetooth"; accel = "Поворот (акселерометр)";
                            power = "Батарея и зарядка"; backlight = "Яркость экрана"; buttons = "Кнопки"; sleep = "Глубокий сон"; camera = "Камеры"; boot = "Загрузка" }

function New-Row([string]$cat, [string]$part, [string]$level, [string]$found, [string]$driver, [string[]]$notes, [string]$gap = "", [string]$partId = "", $devices = @()) {
    [pscustomobject]@{ Category = $cat; Part = $part; Level = $level; Found = $found; Driver = $driver; Notes = @($notes | Where-Object { $_ }); Gap = $gap
                       PartId = $partId; Devices = @($devices) }
}
function Get-WorseLevel([string]$a, [string]$b) {
    $order = @("ok", "likely", "unknown", "setup", "fail")
    if ($order.IndexOf($b) -gt $order.IndexOf($a)) { return $b }
    return $a
}
# $ctx: @{ Hw; Touch; Devices; Dmi; Panel; Platform; Uefi32 }
function Invoke-Forecast($ctx) {
    $hw = $ctx.Hw; $dmi = $ctx.Dmi; $devs = @($ctx.Devices)
    $rows = @()
    $modalias = Get-DmiModalias $dmi
    $acpiIds = @($devs | Where-Object { $_.Bus -eq "acpi" } | ForEach-Object { $_.Id })
    $seenCats = @{}

    # --- детали из каталога
    foreach ($p in $hw.parts) {
        $alias = @{}
        if ($p.alias) { foreach ($k in $p.alias.PSObject.Properties) { $alias[$k.Name] = [string]$k.Value } }
        $found = @($devs | Where-Object { $_.Bus -eq $p.bus -and (($p.ids -contains $_.Id) -or $alias.ContainsKey($_.Id)) })
        if (-not $found) { continue }
        $seenCats[$p.category] = $true
        # одна строка на деталь: несколько найденных идентификаторов (кнопки, несколько экземпляров) сливаются
        $mLevel = "ok"; $mNotes = @(); $mWhere = @(); $mGap = ""; $mDriver = ""
        foreach ($d in $found) {
            $lid = $d.Id
            if ($alias.ContainsKey($lid)) { $lid = $alias[$lid] }
            $level = "ok"; $notes = @(); $gap = ""
            $where = "{0} {1}" -f $d.Bus.ToUpper(), $d.Id
            if ($lid -ne $d.Id) { $where += " (в Linux $lid)" }
            $where += ", в Windows: " + $d.Status
            if ($d.Status -ne "работает" -and $d.Status -ne "неизвестно") { $notes += "В Windows это устройство не работает ($($d.Status)) — прогноз менее надёжен." }
            # драйвер и конфиг
            $cfgOff = @(); $cfgTxt = @()
            foreach ($c in $p.config.PSObject.Properties) {
                $cfgTxt += "$($c.Name)=$($c.Value.value)"
                if ($c.Value.value -eq "n") { $cfgOff += $c.Name }
                if ($c.Value.note) { $notes += "Конфиг: $($c.Name) — $($c.Value.note)." }
            }
            $driver = $p.source
            if (-not $p.in_kernel -or @($p.config.PSObject.Properties).Count -eq 0) {
                $level = "fail"; $driver = "нет драйвера"
            } elseif ($cfgOff) {
                if ($p.need -like "oot:*") {
                    $level = Get-WorseLevel $level "setup"
                    $notes += "В ядре дистрибутива выключено: $($cfgOff -join ', '). Решение есть: модуль собирается отдельно на планшете (сделано на Digma CITI 1804)."
                    $gap = $p.need
                } else {
                    $level = "fail"; $notes += "В ядре дистрибутива выключено: $($cfgOff -join ', ')."
                }
            }
            $driver = "$driver [$($cfgTxt -join ' ')]"
            # прошивки
            $fws = @($p.firmware)
            if ($p.firmware_by_id -and $p.firmware_by_id.PSObject.Properties[$lid]) { $fws += @($p.firmware_by_id.PSObject.Properties[$lid].Value) }
            foreach ($f in $fws) {
                if (-not $f) { continue }
                if ($f.package) { $notes += "Прошивка $($f.path) — в пакете $($f.package)." }
                else { $level = Get-WorseLevel $level "setup"; $notes += "Прошивки $($f.path) нет в пакетах дистрибутива."; if (-not $gap) { $gap = "firmware:" + $f.path } }
            }
            # что нужно сверх драйвера
            switch ($p.need) {
                "touch-catalog" {
                    $hit = @()
                    if ($ctx.Touch) { $hit = @($ctx.Touch.kernel | Where-Object { Test-DmiMatch $_ $dmi }) }
                    if ($hit) {
                        $t = $hit[0]
                        switch ([string]$t.firmware_source) {
                            "gsl-firmware"        { $notes += "Ядро знает модель «$($t.name)»; прошивка $($t.firmware_name) есть в gsl-firmware, установщик её положит." }
                            "gsl-firmware-folder" { $notes += "Ядро знает модель «$($t.name)»; прошивка — из папки устройства в gsl-firmware (формат заранее не проверен)."; $level = Get-WorseLevel $level "likely" }
                            "efi"                 { $notes += "Ядро знает модель «$($t.name)» и само достаёт прошивку из UEFI." }
                            "not-needed"          { $notes += "Ядро знает модель «$($t.name)»." }
                            default               { $notes += "Ядро знает модель «$($t.name)», но прошивки $($t.firmware_name) нигде нет — нужна прошивка из драйвера Windows."; $level = Get-WorseLevel $level "setup"; $gap = "touch-firmware" }
                        }
                    } else {
                        $level = Get-WorseLevel $level "setup"; $gap = "touch-model"
                        $lh = $null
                        if ($ctx.Local) { $lh = @($ctx.Local.devices | Where-Object { $_.match -and $_.touch_firmware -and (Test-DmiMatch $_ $dmi) })[0] }
                        if ($lh) {
                            $notes += "Ядро эту модель не знает, но она есть в базе установщика: «$($lh.name)» — прошивка" + $(if ($lh.touch_props) { " и параметры тача известны." } else { " известна, размер тача замерим на планшете." })
                        } else {
                            $notes += "Ядро эту модель не знает: нужны прошивка тача и его размеры. Можно выбрать похожую модель из списка или взять прошивку из драйвера тача в Windows."
                        }
                    }
                }
                "windows-nvram" { $level = Get-WorseLevel $level "setup"; if (-not $gap) { $gap = "wifi-nvram" } }
                "windows-hcd"   { $level = Get-WorseLevel $level "setup"; if (-not $gap) { $gap = "bt-hcd" } }
                "windows-fw"    { $level = Get-WorseLevel $level "setup"; if (-not $gap) { $gap = "windows-fw" } }
            }
            # настройки под модель
            if ($p.quirk -eq "hwdb") {
                # ключ, который строит udev (60-sensor.rules): sensor:modalias:<modalias устройства>:<dmi modalias>
                $key = "sensor:modalias:acpi:" + $lid + "::" + $modalias
                $hit = $null
                foreach ($g in $hw.hwdb) {
                    foreach ($pt in $g.patterns) { if ($key -match (ConvertFrom-Glob $pt)) { $hit = $g; break } }
                    if ($hit) { break }
                }
                if ($hit) { $notes += "В systemd есть положение датчика для этой модели: $($hit.props.ACCEL_MOUNT_MATRIX)." }
                else { $level = Get-WorseLevel $level "likely"; $notes += "Положения датчика для этой модели в systemd нет: поворот может идти не в ту сторону. Поправим на планшете (калибровка)."; if (-not $gap) { $gap = "accel-matrix" } }
            } elseif ($p.quirk) {
                $q = @($hw.quirks.($p.quirk) | Where-Object { Test-DmiMatch $_ $dmi })
                if ($q) { $notes += "В ядре есть настройка звука под модель «$($q[0].name)»." }
                else { $level = Get-WorseLevel $level "likely"; $notes += "Настройки звука под эту модель в ядре нет — работают общие. Могут быть перепутаны каналы, не работать микрофон или переключение на наушники (проверяется на планшете)." }
            }
            $mLevel = Get-WorseLevel $mLevel $level
            $mWhere += $where
            foreach ($n in $notes) { if ($mNotes -notcontains $n) { $mNotes += $n } }
            if (-not $mGap) { $mGap = $gap }
            $mDriver = $driver
        }
        if ($p.notes) { $mNotes += @($p.notes) }
        $rows += New-Row $p.category $p.name $mLevel ($mWhere -join "; ") $mDriver $mNotes $mGap $p.id $found
    }

    # --- экран и его поворот
    $pn = $ctx.Panel
    $gpu = @($devs | Where-Object { $_.Bus -eq "pci" -and $_.Id -in @("8086:0F31", "8086:22B0", "8086:22B1") })
    $sNotes = @(); $sLevel = "ok"; $sGap = ""
    $sFound = ($gpu | ForEach-Object { "PCI $($_.Id), в Windows: $($_.Status)" }) -join "; "
    if (-not $gpu) { $sLevel = "unknown"; $sNotes += "Видеоядро Bay/Cherry Trail не найдено." }
    $mon = @($devs | Where-Object { $_.Bus -eq "display" -and $_.Class -eq "Monitor" } | ForEach-Object { $_.Id })
    if ($mon) { $sNotes += "Панель: $($mon -join ', ')." }
    if ($pn -and $pn.NativeWidth -gt 0) {
        $sNotes += "Родное разрешение панели {0}x{1}, в Windows сейчас {2}x{3}." -f $pn.NativeWidth, $pn.NativeHeight, $pn.CurrentWidth, $pn.CurrentHeight
        if ($pn.NativeWidth -lt $pn.NativeHeight) {
            $oq = @($hw.quirks.'panel-orientation' | Where-Object {
                (Test-DmiMatch $_ $dmi) -and $_.width -eq $pn.NativeWidth -and $_.height -eq $pn.NativeHeight -and
                ((-not $_.bios_dates) -or (@($_.bios_dates) -contains $dmi.BIOS_DATE)) })
            if ($oq) { $sNotes += "Панель физически портретная, ядро знает поворот для «$($oq[0].name)» ($($oq[0].orientation))." }
            else {
                $sLevel = Get-WorseLevel $sLevel "setup"; $sGap = "panel-orientation"
                $sNotes += "Панель физически портретная, а записи о повороте для этой модели в ядре нет: при загрузке картинка будет повёрнута на 90°. Решение — параметр ядра с поворотом (направление проверим на планшете)."
            }
        }
    } else { $sNotes += "Родное разрешение панели узнать не удалось — поворот не проверен."; $sLevel = Get-WorseLevel $sLevel "unknown" }
    $rows = @(New-Row "screen" "Экран (видеоядро Intel, драйвер i915)" $sLevel $sFound ("i915 [DRM_I915=$($hw.kernel_config_misc.DRM_I915.value)]") $sNotes $sGap) + $rows

    # --- ядро знает планшет целиком (x86-android-tablets)
    $at = @($hw.quirks.'android-tablets' | Where-Object { Test-DmiMatch $_ $dmi })
    if ($at) {
        $rows += New-Row "boot" "Описание планшета в ядре (x86-android-tablets)" "ok" "DMI" "x86-android-tablets" @("Ядро знает этот планшет («$($at[0].name)») и само добавляет устройства, которые неправильно описаны в прошивке.")
    }
    # --- камеры
    $cams = @($devs | Where-Object { $_.Bus -eq "acpi" -and $_.Id -match $hw.camera_pattern })
    if ($cams) {
        $seenCats["camera"] = $true
        $va = [string]$hw.kernel_config_misc.VIDEO_ATOMISP.value
        $cn = @()
        if ($va -eq "n") { $cn += "Драйвер камер atomisp (VIDEO_ATOMISP) в ядре дистрибутива выключен." }
        $cn += "Даже со своим драйвером камеры Bay/Cherry Trail в Linux работают редко (драйвер экспериментальный, staging). На Digma CITI 1804 проверить не удалось: камеры этого экземпляра неисправны."
        $rows += New-Row "camera" "Камеры (atomisp)" "fail" (($cams | ForEach-Object { "ACPI $($_.Id)" }) -join ", ") "atomisp [VIDEO_ATOMISP=$va]" $cn
    }
    # --- загрузка
    $bNotes = @()
    if ($ctx.Uefi32) { $bNotes += "32-битный UEFI: образ загружается через systemd-bootia32 (проверено на Digma CITI 1804)." }
    if ($ctx.Platform -notin @("Bay Trail", "Cherry Trail")) { $rows += New-Row "boot" "Процессор" "unknown" $ctx.Platform "" @("Это не планшет на Bay Trail / Cherry Trail — прогноз для него не рассчитан.") }
    else { $rows += New-Row "boot" "Процессор $($ctx.Platform)" "ok" $ctx.Platform ("EFI_MIXED=" + $hw.kernel_config_misc.EFI_MIXED.value) $bNotes }
    # --- подсветка: ШИМ встроен в Bay/Cherry Trail, но Windows его обычно не показывает
    if (-not $seenCats.ContainsKey("backlight") -and $ctx.Platform -in @("Bay Trail", "Cherry Trail")) {
        $bl = @($hw.parts | Where-Object { $_.id -eq "backlight-pwm" })[0]
        $blCfg = ""
        if ($bl) { $blCfg = "PWM_LPSS_PLATFORM=" + $bl.config.PWM_LPSS_PLATFORM.value }
        $rows += New-Row "backlight" "Подсветка экрана (ШИМ Intel LPSS)" "setup" "в Windows не виден (встроен в процессор $($ctx.Platform))" "pwm-lpss-platform [$blCfg]" @(
            "На ядре Alpine модули pwm-lpss-platform и axp20x-i2c нужно загружать рано, иначе яркость не регулируется. Решение есть (сделано на Digma CITI 1804).",
            "Вывод сделан по типу процессора, а не по найденному устройству.") "early-modules"
        $seenCats["backlight"] = $true
    }
    # --- чего не нашли
    $missText = @{ touch = "Тачскрин Silead/Goodix/Chipone в Windows не найден."; audio = "Звуковой кодек не найден среди известных."
                   wifi = "Wi-Fi на шине SDIO не найден (возможно, он на PCIe или USB — прогноз для них не делается)."; accel = "Акселерометр не найден среди известных: автоповорота может не быть." }
    foreach ($k in $missText.Keys) {
        if (-not $seenCats.ContainsKey($k)) { $rows += New-Row $k "—" "unknown" "не найдено" "" @($missText[$k]) "not-found-$k" }
    }
    # порядок как в $ForecastCats
    $order = @($ForecastCats.Keys)
    @($rows | Sort-Object { $order.IndexOf($_.Category) })
}
function Show-Forecast($rows) {
    foreach ($r in $rows) {
        $lv = $ForecastLevels[$r.Level]
        Write-Host ""
        Write-Host ("  {0,-24}" -f $ForecastCats[$r.Category]) -NoNewline
        Write-Host ("[{0}]" -f $lv.Text) -ForegroundColor $lv.Color -NoNewline
        Write-Host ("  " + $r.Part)
        if ($r.Found)  { Write-Host ("      найдено : " + $r.Found) -ForegroundColor DarkGray }
        if ($r.Driver) { Write-Host ("      драйвер : " + $r.Driver) -ForegroundColor DarkGray }
        foreach ($n in $r.Notes) { Write-Host ("      - " + $n) -ForegroundColor DarkGray }
    }
    Write-Host ""
    $sum = $rows | Group-Object Level | ForEach-Object { "{0}: {1}" -f $ForecastLevels[$_.Name].Text, $_.Count }
    Write-Host ("  Итого — " + ($sum -join ", "))
}
function Format-ForecastText($rows) {
    $out = @()
    foreach ($r in $rows) {
        $out += ("[{0}] {1}: {2}" -f $ForecastLevels[$r.Level].Text, $ForecastCats[$r.Category], $r.Part)
        if ($r.Found)  { $out += "    найдено : " + $r.Found }
        if ($r.Driver) { $out += "    драйвер : " + $r.Driver }
        foreach ($n in $r.Notes) { $out += "    - " + $n }
        if ($r.Gap) { $out += "    пробел  : " + $r.Gap }
    }
    $out
}

# ------------------------------------------------------------------ архив «отправить нам»
# В архив попадает только то, что перечислено ниже; серийные номера, UUID и имя компьютера не собираются.
# ссылка на новую заявку (Issue) с заполненным заголовком; архив человек прикрепляет сам
function Get-ReportIssueUrl([string]$issuesUrl, $dmi) {
    $title = "Новое устройство: {0} {1}" -f $dmi.SYS_VENDOR, $dmi.PRODUCT_NAME
    $body = "Архив установщика с данными об устройстве — прикреплён ниже (перетащите zip-файл сюда).`n`nПлата: {0} {1}, BIOS {2}" -f $dmi.BOARD_VENDOR, $dmi.BOARD_NAME, $dmi.BIOS_VERSION
    "{0}/new?title={1}&body={2}" -f $issuesUrl, [System.Uri]::EscapeDataString($title), [System.Uri]::EscapeDataString($body)
}
function New-ReportPackage([string]$root, $ctx, $rows, [string]$setupConf, [string[]]$extraFiles, [string]$issuesUrl) {
    $dir = Join-Path $root "Отправить-нам"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $safe = (("{0}-{1}" -f $ctx.Dmi.SYS_VENDOR, $ctx.Dmi.PRODUCT_NAME) -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if (-not $safe) { $safe = "device" }
    $name = "report-{0}-{1}" -f $safe, (Get-Date -Format "yyyyMMdd-HHmm")
    $tmp = Join-Path $env:TEMP ("bt-report-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $report = [ordered]@{
        generated = (Get-Date -Format "yyyy-MM-dd HH:mm")
        dmi = $ctx.Dmi
        dmi_modalias = (Get-DmiModalias $ctx.Dmi)
        platform = $ctx.Platform; cpu = $ctx.Cpu; uefi32 = $ctx.Uefi32
        panel = $ctx.Panel
        devices = @($ctx.Devices | Where-Object { $_.Bus -ne "usb" -or $_.Class -notin @("DiskDrive", "USB") } | Select-Object Bus, Id, Subsys, Name, Class, Status)
        forecast = @($rows | Select-Object Category, Part, Level, Found, Driver, Notes, Gap, PartId)
    }
    [System.IO.File]::WriteAllText((Join-Path $tmp "report.json"), ($report | ConvertTo-Json -Depth 6), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $tmp "forecast.txt"), ((Format-ForecastText $rows) -join "`r`n"), $utf8)
    if ($setupConf -and (Test-Path $setupConf)) { Copy-Item $setupConf (Join-Path $tmp "setup.conf") }
    foreach ($f in @($extraFiles | Where-Object { $_ -and (Test-Path $_) })) {
        $fd = Join-Path $tmp "files"; New-Item -ItemType Directory -Force -Path $fd | Out-Null
        Copy-Item $f $fd
    }
    $zip = Join-Path $dir ($name + ".zip")
    Compress-Archive -Path (Join-Path $tmp "*") -DestinationPath $zip -Force
    Remove-Item -Recurse -Force $tmp
    $readme = @(
        "Здесь лежат архивы с данными о вашем планшете для разработчиков установщика.",
        "",
        "Что сделать: создайте заявку (Issue) в репозитории установщика на GitHub и прикрепите к ней файл $name.zip:",
        "  $issuesUrl/new",
        "  — нужен аккаунт GitHub (бесплатный); файл прикрепляется перетаскиванием в поле описания заявки.",
        "  В заголовке укажите модель планшета. Заявки на GitHub видны всем.",
        "",
        "Что внутри архива:",
        "  report.json  — производитель, модель, плата и версия BIOS (DMI), список устройств, найденных Windows, разрешение экрана;",
        "  forecast.txt — прогноз установщика: что заработает в Linux, а что нет;",
        "  setup.conf   — выбранные в установщике настройки;",
        "  files\       — файлы, которые вы сами добавили в установщик (если были).",
        "Серийные номера, UUID, имя компьютера и личные файлы не собираются. Архив можно открыть и проверить перед отправкой."
    )
    [System.IO.File]::WriteAllText((Join-Path $dir "ПРОЧТИТЕ.txt"), ($readme -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $zip
}
