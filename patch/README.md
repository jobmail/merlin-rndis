# RNDIS TX Timeout Recovery Patch

## Описание

Данный патч добавляет в драйвер `rndis_host` для ядра Linux 2.6.36 механизм автоматического восстановления соединения при возникновении TX Timeout (зависание очереди передатчика).

**Проблема:** При пропадании интернета или сбоях модема FM350 (Fibocom) очередь передатчика зависает, ядро выводит WARNING, но не предпринимает действий для восстановления. Это приводит к нестабильности и необходимости полной перезагрузки роутера.

**Решение:** Патч добавляет две функции:
- `rndis_tx_timeout()` — вызывается при зависании очереди, планирует сброс линка
- `rndis_link_reset()` — выполняет полный цикл восстановления: сброс carrier, завершение URB'ов, detach/attach устройства, аппаратный reset модема

Также экспортируется функция `usbnet_terminate_urbs()` из модуля `usbnet`, чтобы `rndis_link_reset` могла её вызывать.

## Файлы

| Файл | Изменения |
|:---|:---|
| `rndis_host.c` | Добавлены `rndis_tx_timeout()`, `rndis_link_reset()`, изменён `rndis_netdev_ops`, добавлено поле `.link_reset` |
| `usbnet.c` | Экспортирована `usbnet_terminate_urbs()` через `EXPORT_SYMBOL_GPL` |

## Требования

- Ядро Linux 2.6.36 (Asuswrt-Merlin для RT-AC88U)
- В ядре должен быть определён `EVENT_LINK_RESET` (проверка: `grep -r "EVENT_LINK_RESET" include/linux/usb/usbnet.h`)

## Применение патча

### Шаг 1: Перейти в директорию ядра

```bash
cd /home/virus/dev/amng/release/src-rt-7.14.114.x/src/linux/linux-2.6.36
```

### Шаг 2: Проверить совместимость патча (dry-run)
```bash
patch --dry-run -p1 < /path/to/rndis_tx_timeout_fix.patch
```

Если нет ошибок — можно применять.

### Шаг 3: Применить патч
```bash
patch -p1 < /path/to/rndis_tx_timeout_fix.patch
```

### Шаг 4: Пересобрать прошивку
```bash
cd /home/virus/dev/amng/release/src-rt-7.14.114.x/src
make rt-ac88u
```
### Шаг 5: Установить на роутер

Заменить модули на роутере:
```bash
# Скопировать новые модули
scp -O rndis_host.ko admin@192.168.10.1:/tmp/
scp -O usbnet.ko admin@192.168.10.1:/tmp/

# На роутере
ssh admin@192.168.10.1
rmmod rndis_host
rmmod usbnet
cp /tmp/rndis_host.ko /lib/modules/2.6.36.4brcmarm/kernel/drivers/net/usb/
cp /tmp/usbnet.ko /lib/modules/2.6.36.4brcmarm/kernel/drivers/net/usb/
depmod -a

Или перепрошить роутер полной прошивкой.
```

### Проверка работы

После установки, при пропадании интернета в логе ядра должны появиться строки:
```text
rndis_host 2-2:1.0: eth3: rndis: TX timeout, scheduling link reset
rndis_host 2-2:1.0: eth3: rndis: starting link reset...
rndis_host 2-2:1.0: eth3: rndis: link reset complete
```

### Посмотреть лог ядра:
```bash
dmesg | grep -i rndis
```

### Механизм восстановления

    TX Timeout → ядро вызывает rndis_tx_timeout()

    rndis_tx_timeout() → планирует EVENT_LINK_RESET через usbnet_defer_kevent()

    keventd → вызывает rndis_link_reset()

    rndis_link_reset() → выполняет полный цикл сброса:

        netif_carrier_off(net) — отключает carrier

        usbnet_terminate_urbs(dev) — завершает все активные URB'ы

        netif_device_detach(net) / netif_device_attach(net) — переподключает устройство

        dev->driver_info->reset(dev) — аппаратный сброс модема

        netif_carrier_on(net) — включает carrier

        netif_wake_queue(net) — возобновляет очередь

### Примечания

    Патч проверен на ядре 2.6.36.4brcmarm (Asuswrt-Merlin 386.14_2)

    Модем: Fibocom FM350-GL

    Роутер: Asus RT-AC88U

    Патч не вызывает паники ядра, корректно обрабатывает WARNING от dev_watchdog

### Автор

Доработка выполнена в рамках проекта по стабилизации работы USB-модема FM350 на роутерах Asuswrt-Merlin.
