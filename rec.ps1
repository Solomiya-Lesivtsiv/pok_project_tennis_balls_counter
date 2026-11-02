# Запис роликів з тепловізора на платі RV1126 і перетворення їх у кадри.
#
# Покласти в папку platform-tools поруч з adb.exe і convert_raw.py.
# Запуск з PowerShell у цій папці:
#
#   powershell -ExecutionPolicy Bypass -File .\rec.ps1                 записати 10 с, скопіювати, перетворити
#   powershell -ExecutionPolicy Bypass -File .\rec.ps1 -Seconds 20     записати 20 с
#   powershell -ExecutionPolicy Bypass -File .\rec.ps1 -RecordOnly     лише записати на плату (швидко, для вулиці)
#   powershell -ExecutionPolicy Bypass -File .\rec.ps1 -Collect        забрати з плати все записане й перетворити
#
# Додаткові параметри: -Flip 180 | v | h | none,  -Every 5,  -Skip 10,  -DeleteRaw
# Усе складається в папку dataset, опис кожного ролика — у dataset\journal.csv

param(
    [int]$Seconds = 10,
    [int]$Every = 5,
    [int]$Skip = 10,
    [string]$Flip = "none",
    [switch]$RecordOnly,
    [switch]$Collect,
    [switch]$DeleteRaw
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8   # щоб українські повідомлення Python не були кракозябрами
$env:PYTHONIOENCODING = "utf-8"
Set-Location $PSScriptRoot
$adb = Join-Path $PSScriptRoot "adb.exe"
$ds = Join-Path $PSScriptRoot "dataset"
$journal = Join-Path $ds "journal.csv"
$frameBytes = 1310720          # один кадр 1280x512 YUYV

New-Item -ItemType Directory -Force $ds | Out-Null
if (-not (Test-Path $journal)) {
    "name,time,seconds,description,saved_frames" | Out-File -Encoding UTF8 $journal
}

function Check-Board {
    $dev = & $adb devices | Select-String "`tdevice"
    if (-not $dev) {
        Write-Host "Плату не видно. Перевірте кабель (з передачею даних) і зачекайте ~30 с після ввімкнення." -ForegroundColor Red
        exit 1
    }
}

function Find-Camera {
    # Увесь вивід одним текстом; беремо перший /dev/videoN після слова InfraredCamera
    $txt = (& $adb shell "v4l2-ctl --list-devices") -join "`n"
    if ($txt -match "InfraredCamera[\s\S]*?(/dev/video\d+)") { return $Matches[1] }
    Write-Host "Тепловізор не знайдено в списку пристроїв плати. Вивід v4l2-ctl:" -ForegroundColor Red
    Write-Host $txt
    exit 1
}

function Next-Name {
    $max = 0
    Get-Content $journal | ForEach-Object {
        if ($_ -match "^rec(\d+),") { $max = [Math]::Max($max, [int]$Matches[1]) }
    }
    return "rec{0:D2}" -f ($max + 1)
}

function Convert-One([string]$name) {
    $local = Join-Path $ds "$name.raw"
    Write-Host "Копіюю $name.raw з плати (це може зайняти 1-3 хв)..."
    & $adb pull "/userdata/$name.raw" $ds | Out-Host
    if (-not (Test-Path $local)) {
        Write-Host "Файл не скопіювався." -ForegroundColor Red
        return 0
    }
    $n = [Math]::Floor((Get-Item $local).Length / $frameBytes)
    Write-Host "У записі $n кадрів."

    python convert_raw.py $local --every $Every --skip $Skip --flip $Flip --no-raw --out (Join-Path $ds "${name}_frames") | Out-Host

    & $adb shell "rm -f /userdata/$name.raw" | Out-Null
    if ($DeleteRaw) { Remove-Item $local | Out-Null }

    $saved = (Get-ChildItem (Join-Path $ds "${name}_frames\y8") -Filter *.png -ErrorAction SilentlyContinue).Count
    return $saved
}

Check-Board

# ---------- Режим -Collect: забрати все записане з плати ----------
if ($Collect) {
    # ls через adb може виводити кілька файлів в одному рядку (колонками),
    # тому витягуємо всі назви recNN.raw з тексту регулярним виразом
    $txt = (& $adb shell "ls -1 /userdata/ 2>/dev/null") -join " "
    $names = [regex]::Matches($txt, "rec\d+(?=\.raw)") | ForEach-Object { $_.Value } | Sort-Object -Unique
    if (-not $names) { Write-Host "На платі немає записів rec*.raw."; exit 0 }
    Write-Host ("На платі записів: {0} ({1})" -f $names.Count, ($names -join ", ")) -ForegroundColor Cyan
    foreach ($name in $names) {
        $saved = Convert-One $name
        Write-Host "$name : збережено $saved кадрів у dataset\${name}_frames\y8" -ForegroundColor Green
    }
    $free = & $adb shell "df -h /userdata | tail -1"
    Write-Host "Місце на платі: $free"
    exit 0
}

# ---------- Запис нового ролика ----------
$cam = Find-Camera
$name = Next-Name
Write-Host "Камера: $cam   Наступний ролик: $name   Тривалість: $Seconds с" -ForegroundColor Cyan
$desc = Read-Host "Опис (місце, відстань, що відбувається)"
$desc = $desc -replace ",", ";"

Read-Host "Наведіть камеру і натисніть Enter, щоб почати запис"
$count = $Seconds * 30 + $Skip
$tmo = $Seconds + 15
# Після ввімкнення плати перший запуск потоку часто зависає (камера перезапускається),
# тому до 3 спроб: якщо файл порожній — шукаємо камеру знову і пишемо ще раз.
$expected = [int64]$count * $frameBytes
$bytes = 0
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "ЗАПИС... ($Seconds с), спроба $attempt" -ForegroundColor Yellow
    & $adb shell "rm -f /userdata/$name.raw; timeout $tmo v4l2-ctl -d $cam --set-fmt-video=width=1280,height=512,pixelformat=YUYV --stream-mmap --stream-count=$count --stream-to=/userdata/$name.raw" | Out-Null
    $out = (& $adb shell "wc -c < /userdata/$name.raw 2>/dev/null") -join ""
    $bytes = 0
    [void][int64]::TryParse($out.Trim(), [ref]$bytes)
    if ($bytes -ge $frameBytes * ($Skip + 30)) { break }
    Write-Host "Камера не віддала кадри ($bytes байт). Чекаю 5 с і пробую ще раз..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 5
    $cam = Find-Camera
    Write-Host "Камера: $cam"
}
if ($bytes -lt $frameBytes * ($Skip + 30)) {
    & $adb shell "rm -f /userdata/$name.raw" | Out-Null
    Write-Host "Запис не вдався. Ролик НЕ додано в журнал. Скиньте вивід: .\adb shell `"dmesg | tail -20`"" -ForegroundColor Red
    exit 1
}
Write-Host ("Запис завершено: {0} кадрів з {1}." -f [Math]::Floor($bytes / $frameBytes), $count) -ForegroundColor Green
if ($bytes -lt $expected) {
    Write-Host "Увага: частина кадрів загубилась (обірвався потік). Ролик збережено, але гляньте його." -ForegroundColor DarkYellow
}

$saved = ""
if (-not $RecordOnly) {
    $saved = Convert-One $name
    Write-Host "$name : збережено $saved кадрів у dataset\${name}_frames\y8" -ForegroundColor Green
} else {
    $free = & $adb shell "df -h /userdata | tail -1"
    Write-Host "Ролик лишився на платі. Пізніше: rec.ps1 -Collect.  Місце: $free"
}

"$name,$(Get-Date -Format 'yyyy-MM-dd HH:mm'),$Seconds,$desc,$saved" | Out-File -Append -Encoding UTF8 $journal
