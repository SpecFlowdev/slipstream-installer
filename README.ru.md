<div align="center">

[English](README.md) · **Русский**

<img src="assets/banner.svg" alt="Slipstream Server Installer" width="100%">

### Установщик в одну команду для **сервера** DNS-туннеля [slipstream](https://github.com/Mygod/slipstream-rust)

Linux · x86_64 · arm64

[![Лицензия](https://img.shields.io/badge/license-Apache--2.0-3b82f6?style=flat-square)](LICENSE)
[![Upstream](https://img.shields.io/badge/slipstream-v0.1.1-22d3a8?style=flat-square)](https://github.com/Mygod/slipstream-rust/releases/tag/v0.1.1)
[![Установка](https://img.shields.io/badge/установка-готовый%20бинарник-38bdf8?style=flat-square)](#установка)
[![Сервис](https://img.shields.io/badge/systemd-изолирован-a78bfa?style=flat-square)](#безопасность)

</div>

---

## Установка

Запускайте на машине, которая будет держать сервер туннеля:

```sh
curl -fsSL https://raw.githubusercontent.com/SpecFlowdev/slipstream-installer/main/install.sh | sudo bash
```

---

## Требования

- **Linux с systemd**, x86_64 или arm64
- **Root** — чтобы установить сервис и занять DNS-порт
- **Свой домен**, чью `NS`-запись можно направить на этот хост
- **Доступный UDP** на порту прослушивания, по умолчанию 53

---

## Зачем этот установщик

- **Без компиляции** — ставится готовый бинарник из релиза. Сборка slipstream из исходников тянет picoquic, picotls и OpenSSL через CMake; здесь всё занимает секунды.
- **Спрашивает, а не угадывает** — домен и цель форвардинга запрашиваются при запуске, так что ошибиться в командной строке негде. Ввод читается напрямую с терминала, поэтому работает даже через `curl | bash`.
- **Вшитые контрольные суммы** — SHA256 каждого архива зашит в скрипт, а не просто скачивается рядом с архивом.
- **Не root во время работы** — сервис запускается под непривилегированным пользователем и биндит порт 53 через одну-единственную привилегию.
- **Разбирается с конфликтом на порту 53** — находит stub-listener `systemd-resolved`, который на Ubuntu и Debian молча ломает привязку к DNS-порту, и предлагает его отключить.
- **TLS настраивается сам** — сервер генерирует сертификат при первом старте. Ни CA, ни ACME, ни лишнего открытого порта.

---

## Что устанавливается

| Путь | Содержимое |
| --- | --- |
| `/usr/local/bin/slipstream-server` | Бинарник сервера — его и запускает сервис |
| `/usr/local/bin/slipstream-client` | Бинарник клиента, идёт в том же архиве; удобен, чтобы проверить туннель с самого сервера |
| `/etc/slipstream/` | `cert.pem`, `key.pem` — создаются при первом старте |
| `/var/lib/slipstream/reset-seed` | Seed для stateless reset, переживает перезапуски |
| `/etc/systemd/system/slipstream-server.service` | Unit сервиса |

---

## Безопасность

**Вшитые контрольные суммы.** Архивы релиза сверяются с SHA256, зашитым в `install.sh`. Проверка только по файлу `.sha256`, лежащему рядом с архивом, не поймала бы подмену релиза: тот, кто может заменить одно, заменит и другое. При установке версии, отличной от штатной, скрипт откатывается на опубликованную сумму этого релиза и честно об этом предупреждает.

**Не root во время работы.** Сервис работает под непривилегированным системным пользователем `slipstream`. Право занять порт 53 даёт одна лишь `CAP_NET_BIND_SERVICE`, а не запуск от root; `NoNewPrivileges` закрывает повышение привилегий.

**Изоляция.** `ProtectSystem=strict` с `ReadWritePaths`, суженным до собственных каталогов конфигурации и состояния, плюс `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `ProtectProc=invisible`, защита ядра, cgroups и часов, `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute` и seccomp-фильтр `@system-service`.

**Docker нет — намеренно.** Upstream не публикует контейнерный образ. Установка через Docker добавила бы в поверхность атаки root-эквивалентный сокет демона, ничего не выиграв по сравнению с изоляцией выше.

**Сертификаты.** Сервер при первом старте генерирует self-signed сертификат на P-256, а клиент пиннит именно этот leaf. Никакому CA доверять не нужно, порт под ACME-проверку открывать тоже.

---

## Управление сервисом

```sh
systemctl status slipstream-server      # состояние
journalctl -u slipstream-server -f      # смотреть логи
systemctl restart slipstream-server     # перезапуск
```

---

## Удаление

```sh
sudo systemctl disable --now slipstream-server
sudo rm -f /etc/systemd/system/slipstream-server.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/slipstream-{server,client}
sudo rm -rf /etc/slipstream /var/lib/slipstream
sudo userdel slipstream
```

---

<div align="center">

Apache-2.0 · Устанавливает [Mygod/slipstream-rust](https://github.com/Mygod/slipstream-rust)

</div>
