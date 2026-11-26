# Общие функции вопросов и вывода для установщика и проверок.
# Подключается через: . (Join-Path $Root "lib\ui.ps1")
function Title([string]$t) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}
# Read-Host возвращает $null, только когда ввод закрыт (ответы подавались из файла и кончились) — тогда выходим, а не крутимся
function Read-Answer([string]$prompt) {
    $a = Read-Host $prompt
    if ($null -eq $a) { throw "Ввод закончился — установщик остановлен." }
    [string]$a
}
function Ask-Number([string]$prompt, [int]$min, [int]$max) {
    while ($true) {
        $a = Read-Answer $prompt
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
        Write-Host "  Введите число от $min до $max." -ForegroundColor Yellow
    }
}
function Ask-YesNo([string]$prompt) {
    while ($true) {
        $a = (Read-Answer ($prompt + " [д/н]")).Trim().ToLower()
        if ($a -in @("д","да","y","yes")) { return $true }
        if ($a -in @("н","нет","n","no")) { return $false }
    }
}
function Show-TouchChoice($c) {
    Write-Host ""
    Write-Host ("  Модель   : " + $c.Model)
    if ($c.PSObject.Properties["FwLocal"] -and $c.FwLocal) { Write-Host ("  Прошивка : {0} ({1:N0} байт, git sha1 {2})" -f $c.FwName, $c.FwSize, $c.FwSha1) }
    elseif ($c.FwUrl -and $c.FwSize -gt 0) { Write-Host ("  Прошивка : {0} ({1:N0} байт)" -f $c.FwName, $c.FwSize) }
    elseif ($c.FwUrl) { Write-Host ("  Прошивка : {0}" -f $c.FwName) }
    elseif ($c.FwName) { Write-Host ("  Прошивка : {0} — скачивать нечего" -f $c.FwName) }
    if ($c.Props) { Write-Host ("  Параметры: " + $c.Props) }
    foreach ($n in $c.Notes) { Write-Host ("  - " + $n) -ForegroundColor DarkGray }
}
