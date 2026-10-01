#Requires -Version 5.1
<#
.SYNOPSIS
    Восстанавливает USB-принтер, который Windows удалила из-за Windows Protected Print Mode (WPP).

.DESCRIPTION
    Начиная с Windows 11 24H2 (а в сборках 26016+ режим включён по умолчанию) Windows
    может самостоятельно включить Windows Protected Print Mode. При включении WPP:

      * принтеры, работающие через сторонние (не Mopria) драйверы, удаляются;
      * их драйверы стираются из хранилища драйверов;
      * установка сторонних драйверов блокируется.

    В результате принтер пропадает из системы, а в Диспетчере устройств остаётся только
    «Поддержка USB принтера» (usbprint.inf) — без дочернего устройства USBPRINT\...,
    то есть без очереди печати.

    Скрипт отключает WPP, ставит драйвер из INF-файла вендора, создаёт очередь печати
    на USB-порту и переключает обработчик печати на стандартный winprint.

    Скрипт ничего не удаляет: отключение WPP возвращает систему в состояние, в котором
    сторонние драйверы принтеров снова разрешены.

.PARAMETER InfPath
    Путь к INF-файлу драйвера принтера, например ...\Driver\OKB3E03X.INF

.PARAMETER DriverName
    Имя драйвера ровно так, как оно указано в секции [Manufacturer] INF-файла.
    Посмотреть список доступных имён можно командой:
        Get-Content <INF> | Select-String '^"'

.PARAMETER PrinterName
    Имя, под которым будет создана очередь печати. По умолчанию — DriverName.

.PARAMETER PortName
    Порт печати. Для USB-принтера это обычно USB001. Список портов: Get-PrinterPort

.PARAMETER KeepOkiPrintProcessor
    Не переключать обработчик печати на winprint.
    По умолчанию скрипт переключает, потому что родной обработчик OKI (OPATPP3)
    на Windows 11 роняет задания с ошибками Win32 170 и 2.

.EXAMPLE
    .\fix-wpp-printer.ps1 -InfPath 'C:\Drivers\OKB3E03X.INF' -DriverName 'OKI B431(PCL)'

.EXAMPLE
    .\fix-wpp-printer.ps1 -InfPath 'C:\Drivers\OKB3E03X.INF' -DriverName 'OKI B431(PCL)' `
        -PrinterName 'OKI B431' -PortName 'USB001'

.NOTES
    Требуются права администратора. После отключения WPP рекомендуется перезагрузка,
    но установка драйвера и создание очереди работают и без неё.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InfPath,

    [Parameter(Mandatory = $true)]
    [string]$DriverName,

    [string]$PrinterName,
    [string]$PortName = 'USB001',
    [switch]$KeepOkiPrintProcessor
)

$ErrorActionPreference = 'Stop'

$WppPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP'
$PrintKey     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Нужны права администратора. Запустите PowerShell от имени администратора.'
    }
}

function Get-WppState {
    $policy = if (Test-Path $WppPolicyKey) {
        (Get-ItemProperty -Path $WppPolicyKey -Name 'WindowsProtectedPrintMode' -ErrorAction SilentlyContinue).WindowsProtectedPrintMode
    }
    $state = (Get-ItemProperty -Path $PrintKey -Name 'WindowsProtectedPrintState' -ErrorAction SilentlyContinue).WindowsProtectedPrintState
    [pscustomobject]@{ PolicyValue = $policy; StateValue = $state }
}

function Disable-WindowsProtectedPrint {
    $before = Get-WppState
    Write-Host ("WPP до исправления: policy={0} state={1}" -f $before.PolicyValue, $before.StateValue)

    if (Test-Path $WppPolicyKey) {
        # WindowsProtectedPrintMode = 0 возвращает режим в выключенное состояние,
        # EnabledBy = 0 снимает признак «включено политикой или пользователем».
        Set-ItemProperty -Path $WppPolicyKey -Name 'WindowsProtectedPrintMode' -Value 0 -Type DWord
        Set-ItemProperty -Path $WppPolicyKey -Name 'EnabledBy'                 -Value 0 -Type DWord

        # Эти два значения относятся только к состоянию «включено».
        foreach ($name in 'WindowsProtectedPrintGroupPolicyState', 'WindowsProtectedPrintOobeConfigComplete') {
            if (Get-ItemProperty -Path $WppPolicyKey -Name $name -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -Path $WppPolicyKey -Name $name
            }
        }
    }
    else {
        Write-Host 'Ключ политики WPP отсутствует — режим не был включён через реестр.'
    }

    # Рабочее состояние подсистемы печати: 0 = защищённый режим выключен.
    Set-ItemProperty -Path $PrintKey -Name 'WindowsProtectedPrintState' -Value 0 -Type DWord

    Restart-Service -Name Spooler -Force
    Start-Sleep -Seconds 3

    $after = Get-WppState
    Write-Host ("WPP после исправления: policy={0} state={1}" -f $after.PolicyValue, $after.StateValue)
}

function Install-PrinterDriverPackage {
    Write-Host "Добавление пакета драйвера в хранилище: $InfPath"

    # pnputil копирует пакет в DriverStore. После этого Add-PrinterDriver
    # находит драйвер по имени. Передавать -InfPath напрямую в Add-PrinterDriver
    # на этой сборке Windows не работает: возвращается 0x80070057.
    $output = & pnputil.exe /add-driver "$InfPath" /install 2>&1
    $output | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -ne 0) {
        throw "pnputil не смог добавить пакет драйвера (код $LASTEXITCODE)."
    }
}

function Install-PrinterDriver {
    $existing = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Драйвер '$DriverName' уже установлен."
        return
    }

    try {
        Add-PrinterDriver -Name $DriverName -ErrorAction Stop
        Write-Host "Драйвер '$DriverName' установлен."
    }
    catch {
        throw "Не удалось установить драйвер '$DriverName'. Проверьте, что имя точно совпадает " +
              "с записью в INF-файле. Ошибка: $($_.Exception.Message)"
    }
}

function New-PrinterQueue {
    if (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue) {
        Write-Host "Очередь печати '$PrinterName' уже существует."
        return
    }

    if (-not (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
        throw "Порт '$PortName' не найден. Подключите принтер и проверьте Get-PrinterPort."
    }

    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
    Write-Host "Очередь печати '$PrinterName' создана на порту $PortName."
}

function Set-StandardPrintProcessor {
    # Родной обработчик OKI (OPATPP3) на Windows 11 возвращает заданиям ошибки
    # Win32 170 (ERROR_BUSY) и 2 (ERROR_FILE_NOT_FOUND), и печать не проходит.
    # Стандартный winprint печатает те же данные нормально.
    Set-Printer -Name $PrinterName -PrintProcessor 'winprint' -Datatype 'RAW'
    Write-Host "Обработчик печати переключён на winprint (тип данных RAW)."
}

function Show-Result {
    Write-Host ''
    Write-Host '=== Результат ==='
    Get-Printer -Name $PrinterName |
        Format-List Name, DriverName, PortName, PrintProcessor, Datatype, PrinterStatus

    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USBPRINT*' } |
        Format-Table Status, FriendlyName, InstanceId -AutoSize
}

Assert-Administrator

if (-not $PrinterName) { $PrinterName = $DriverName }

Write-Host '=== 1. Отключение Windows Protected Print Mode ==='
Disable-WindowsProtectedPrint

Write-Host '=== 2. Установка драйвера ==='
Install-PrinterDriverPackage
Install-PrinterDriver

Write-Host '=== 3. Создание очереди печати ==='
New-PrinterQueue

if (-not $KeepOkiPrintProcessor) {
    Write-Host '=== 4. Обработчик печати ==='
    Set-StandardPrintProcessor
}

Show-Result

Write-Host ''
Write-Host 'Готово. Отправьте пробную страницу:'
Write-Host ("  `$p = Get-CimInstance Win32_Printer -Filter `"Name='{0}'`"" -f $PrinterName)
Write-Host '  Invoke-CimMethod -InputObject $p -MethodName PrintTestPage'
Write-Host ''
Write-Host 'Проверить, что задание реально ушло на принтер:'
Write-Host '  Get-WinEvent -LogName ''Microsoft-Windows-PrintService/Operational'' -MaxEvents 10'
Write-Host '  (событие 307 = документ распечатан)'
