# Windows Protected Print Mode удалил USB-принтер: диагностика и восстановление

Скрипт для Windows 11, который возвращает USB-принтер со сторонним (не Mopria) драйвером,
удалённый Windows Protected Print Mode.

Проверено на: Windows 11 сборка 26300 (26H2), USB-принтер OKI B431 (VID_06BC&PID_0269),
драйвер `OKB3E03X.INF` версии 1.1.5.0.

## Симптом

Принтер был подключён и работал. После очередного включения компьютера:

- в «Принтеры и сканеры» принтера нет, есть только виртуальные (Print to PDF);
- в Диспетчере устройств остаётся **«Поддержка USB принтера»** с драйвером `usbprint.inf`
  и статусом «работает нормально»;
- дочернего устройства `USBPRINT\...` (собственно принтера) нет;
- повторная установка драйвера вендора не проходит.

Самое неприятное в этом симптоме: Диспетчер устройств показывает всё исправным.
«Поддержка USB принтера» — это лишь транспортный класс USB, он не означает,
что принтер настроен.

## Причина

Windows 11 сама включила **Windows Protected Print Mode (WPP)**.

В сборках Windows 11 26016 и новее этот режим включён по умолчанию. Когда он включается,
Windows удаляет принтеры, использующие сторонние драйверы, и стирает сами драйверы
из хранилища. Пока режим активен, установить сторонний драйвер невозможно.

WPP рассчитан только на принтеры с сертификацией Mopria (печать через IPP универсальным
драйвером). Драйвер OKI B431 выпущен в 2013 году, Mopria не поддерживает, поэтому под WPP
он не работает. OKI подтверждает это в своей базе знаний: при использовании их драйвера
защищённый режим печати включать нельзя.

На Linux такого механизма нет — поэтому там тот же принтер продолжал определяться.

### Доказательства из системы

Включение режима и удаление принтера видны в журнале конфигурации PnP
(`Microsoft-Windows-Kernel-PnP/Configuration`):

| Время | Событие |
|---|---|
| 11:25:39 | `WindowsProtectedPrintMode` установлен в 1 |
| 11:28:03 | Удалено устройство `USBPRINT\OKI_DATA_CORPB431\...` |
| 11:28:03 | Удалено устройство `USB\VID_06BC&PID_0269\AK26029374` |
| 11:28:22 | Устройство переустановлено только как «Поддержка USB принтера» |

Состояние режима — в реестре:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP
    WindowsProtectedPrintMode = 1     <- режим включён
    EnabledBy                 = 1
    EnabledTimestamp          = ...

HKLM\SYSTEM\CurrentControlSet\Control\Print
    WindowsProtectedPrintState = 1    <- подсистема печати в защищённом режиме
```

В `C:\Windows\INF\setupapi.dev.log` попытка установить драйвер вендора заканчивается
`Exit status: FAILURE(0x000004c7)`.

## Исправление

```powershell
# Запустить PowerShell от имени администратора
.\fix-wpp-printer.ps1 -InfPath 'C:\Drivers\OKB3E03X.INF' -DriverName 'OKI B431(PCL)'
```

Скрипт делает пять шагов:

1. **Отключает WPP** — `WindowsProtectedPrintMode = 0`, `EnabledBy = 0`
   и `WindowsProtectedPrintState = 0`. Без этого шага драйвер не установится.
2. **Перезапускает службу печати** (Spooler).
3. **Добавляет пакет драйвера** через `pnputil /add-driver <INF> /install`.
4. **Устанавливает драйвер** по имени и **создаёт очередь печати** на USB-порту.
5. **Переключает обработчик печати** на стандартный `winprint`.

### Почему обработчик печати приходится менять

Родной обработчик OKI (`OPATPP3`) на Windows 11 принимает задание, отправляет данные
на принтер, но затем падает. В журнале `Microsoft-Windows-PrintService/Admin`
появляются события 372 с кодами Win32:

- `170` — `ERROR_BUSY`, «требуемый ресурс занят»;
- `2` — `ERROR_FILE_NOT_FOUND`, «не удалось найти указанный файл».

Стандартный `winprint` те же данные обрабатывает без ошибок. Это обходной путь:
он лечит печать, но фирменные функции драйвера OKI (например, расход тонера
и состояние лотков) могут быть недоступны.

### Ограничение

Скрипт не устанавливает драйвер сам и не содержит его — INF-файл нужно взять
у производителя принтера. Драйверы вендора распространяются по своим лицензиям,
и перепубликовать их в открытом репозитории нельзя.

## Проверка результата

```powershell
$p = Get-CimInstance Win32_Printer -Filter "Name='OKI B431'"
Invoke-CimMethod -InputObject $p -MethodName PrintTestPage
```

Важно: `(Get-CimInstance ...).PrintTestPage()` не сработает — у объекта CIM нет такого
метода, нужен `Invoke-CimMethod`.

Убедиться, что задание действительно дошло до принтера, а не просто исчезло из очереди:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-PrintService/Operational' -MaxEvents 10
```

Событие **307** означает, что документ распечатан. Ошибки печати попадают
в `Microsoft-Windows-PrintService/Admin` (событие 372).

## Что делать, чтобы не повторилось

- Не включать «Защищённый режим печати» в Параметры → Bluetooth и устройства →
  Принтеры и сканеры. При включении принтер снова отвалится.
- Обновление Windows может включить WPP обратно. Если принтер исчез — первым делом
  проверять `WindowsProtectedPrintMode` в реестре.

## Источники

- [Windows Protected Print Mode — Microsoft Learn](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode)
- [Windows Protected Print Mode for Enterprises — Microsoft Learn](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode-for-enterprises)
- [OKI: совместимость драйверов с Windows 11](https://okiprinting-en-gb.custhelp.com/app/answers/detail/a_id/30980/kw/B431dn)

## Лицензия

MIT — см. [LICENSE](LICENSE).
