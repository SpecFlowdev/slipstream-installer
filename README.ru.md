<div align="center">

[English](README.md) · **Русский**

<img src="assets/banner.svg" alt="Slipstream Installer" width="100%">

### Установщик в одну команду для сервера DNS-туннеля [slipstream](https://github.com/Mygod/slipstream-rust)

Linux · x86_64 · arm64

[![Лицензия](https://img.shields.io/badge/license-Apache--2.0-3b82f6?style=flat-square)](LICENSE)
[![Upstream](https://img.shields.io/badge/slipstream-v0.1.1-22d3a8?style=flat-square)](https://github.com/Mygod/slipstream-rust/releases/tag/v0.1.1)
[![Установка](https://img.shields.io/badge/установка-готовый%20бинарник-38bdf8?style=flat-square)](#установка)
[![Сервис](https://img.shields.io/badge/systemd-изолирован-a78bfa?style=flat-square)](#безопасность)

</div>

---

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/SpecFlowdev/slipstream-installer/main/install.sh | sudo bash
```

И всё. Ни флагов, ни аргументов — скрипт спрашивает нужное уже после запуска:

```
==> Tunnel domain (the zone delegated to this host, e.g. t.example.com): t.example.com
==> Forward decrypted traffic to [127.0.0.1:5201]:
==> DNS listen port [53]:

==> Downloading slipstream-linux-x86_64.tar.gz (v0.1.1)
==> Verifying SHA256
==> Installing binaries to /usr/local/bin
==> Creating system user slipstream
==> Writing /etc/systemd/system/slipstream-server.service
==> Enabling and starting slipstream-server

  slipstream-server is running.
```

Хотите сначала прочитать, а потом запускать? Разумно:

```sh
git clone https://github.com/SpecFlowdev/slipstream-installer
cd slipstream-installer
sudo ./install.sh
```

---

## Зачем этот установщик

- **Без компиляции** — ставится готовый бинарник из релиза. Сборка slipstream из исходников тянет picoquic, picotls и OpenSSL через CMake; здесь всё занимает секунды.
- **Спрашивает, а не угадывает** — домен и цель форвардинга запрашиваются при запуске, так что ошибиться в командной строке негде. Ввод читается напрямую с терминала, поэтому работает даже через `curl | bash`.
- **Вшитые контрольные суммы** — SHA256 каждого архива зашит в скрипт, а не просто скачивается рядом с архивом.
- **Не root во время работы** — сервис запускается под непривилегированным пользователем и биндит порт 53 через одну-единственную привилегию.
- **Разбирается с конфликтом на порту 53** — находит stub-listener `systemd-resolved`, который на Ubuntu и Debian молча ломает привязку к DNS-порту, и предлагает его отключить.
- **TLS настраивается сам** — сервер генерирует сертификат при первом старте. Ни CA, ни ACME, ни лишнего открытого порта.

---

## Настройка

Любой вопрос можно задать заранее через переменную окружения. Если переменная задана, соответствующий запрос пропускается — так тот же скрипт работает без участия человека.

| Переменная | По умолчанию | Значение |
| --- | --- | --- |
| `SLIPSTREAM_DOMAIN` | *(спрашивается)* | Домен туннеля, делегированный на этот хост |
| `SLIPSTREAM_TARGET` | `127.0.0.1:5201` | Куда форвардить расшифрованный трафик |
| `SLIPSTREAM_DNS_PORT` | `53` | UDP-порт, который слушает сервер |
| `SLIPSTREAM_VERSION` | `v0.1.1` | Версия релиза для установки |

```sh
sudo SLIPSTREAM_DOMAIN=t.example.com SLIPSTREAM_TARGET=127.0.0.1:1080 ./install.sh
```

---

## Что устанавливается

| Путь | Содержимое |
| --- | --- |
| `/usr/local/bin/slipstream-server` | Бинарник сервера |
| `/usr/local/bin/slipstream-client` | Бинарник клиента, идёт в том же архиве |
| `/etc/slipstream/` | `cert.pem`, `key.pem` — создаются при первом старте |
| `/var/lib/slipstream/reset-seed` | Seed для stateless reset, переживает перезапуски |
| `/etc/systemd/system/slipstream-server.service` | Unit сервиса |

---

## После установки

**1. Делегируйте домен.** Направьте `NS`-запись домена туннеля на публичный IP этого хоста и откройте UDP на порту прослушивания.

```
t.example.com.    IN  NS  ns1.example.com.
ns1.example.com.  IN  A   203.0.113.10
```

**2. Скопируйте сертификат** из `/etc/slipstream/cert.pem` на клиентскую машину. Клиент пиннит именно этот сертификат, поэтому перенести его нужно один раз вручную.

**3. Подключайтесь.**

```sh
slipstream-client --domain t.example.com --resolver 1.1.1.1:53 \
    --cert ./cert.pem --tcp-listen-port 7000
```

Трафик, отправленный на `127.0.0.1:7000` на клиенте, выходит на цели форвардинга сервера.

---

## Безопасность

**Вшитые контрольные суммы.** Архивы релиза сверяются с SHA256, зашитым в `install.sh`. Проверка только по файлу `.sha256`, лежащему рядом с архивом, не поймала бы подмену релиза: тот, кто может заменить одно, заменит и другое. При переопределении `SLIPSTREAM_VERSION` скрипт откатывается на опубликованную сумму и честно об этом предупреждает.

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
