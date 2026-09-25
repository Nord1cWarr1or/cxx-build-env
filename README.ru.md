# cxx-build-env

**[English](https://github.com/Nord1cWarr1or/cxx-build-env/blob/main/README.md)** | **Русский**

Docker-образы для сборки 32- и 64-битного C/C++, плюс `csbuild.sh` — раннер, который собирает сторонние проекты экосистемы CS 1.6 (ReGameDLL, reapi, AMXX-модули) внутри этих образа средствами самого проекта и с его флагами, а бинарники кладёт на ваш хост, а не в контейнер.

## Образы

| Дистрибутив | glibc | GCC | Binutils | CMake | Дополнительно |
|-------------|-------|-----|----------|-------|---------------|
| **Oracle Linux 7** | 2.17 | 16.2.0 | 2.47 + gold 2.43 | 3.31.12 | Make 4.4.1, Ninja, Mold, NASM 3.02, OpenSSL 3.6.4, Go 1.27.1, Cppcheck 2.21.0, AMBuild |
| **Debian 11** | 2.31 | 10.2.1 | 2.35.2 | 3.18.4 | NASM 2.15, AMBuild, Python 3 |
| **Ubuntu 24.04** | 2.39 | 16.0.1 | 2.47 | 3.31.12 | Make 4.4.1, Ninja, Mold, NASM 3.02, OpenSSL 3.6.4, Go 1.27.1, Cppcheck 2.21.0, AMBuild; Clang 20.1.8 и IWYU в образе `clang` |

В экосистеме CS 1.6 две эпохи тулчейнов, и один компилятор не покрывает обе:

- **Oracle Linux 7** (GCC 16.2) собирает современный C++ (rehlds-m, amxx-nova-pc) и даёт бинарники, которые работают на старых серверах с glibc 2.17.
- **Debian 11** (GCC 10.2) существует потому, что ряд проектов держит авторские флаги, которые понимает только старый GCC. `-fno-plt` в ReGameDLL на i386 заставляет GCC 14+ генерировать GOT32X-релокации, которые binutils отвергает (проверено на 2.40 и 2.47); AMXX-модули той эпохи со старым AMTL и `-Werror` на новых компиляторах умирают так же.

Честно о границах: неподдерживаемые случаи — сборки под icc (ReInfoZone жёстко прописывает `/opt/intel/bin/icpc`), сломанные апстримы и MSVC-only раскладки, линкующиеся с кучей невендоренных репозиториев.

## Требования

- Docker. Сборка образов работает и на BuildKit, и на legacy-билдере (`build.sh` при отказе от `COPY "../scripts"` сам перезапускается с context-relative Dockerfile).
- Для `csbuild.sh`: `git` и GNU coreutils/findutils. На macOS: `brew install coreutils findutils gnu-sed`.

## Установка

```bash
git clone https://github.com/hun1er/cxx-build-env.git
cd cxx-build-env
```

Больше ничего ставить не нужно — `build.sh` и `csbuild.sh` запускаются из репозитория, образы скачиваются автоматически при первом использовании.

## Использование

### Сборка образов

```bash
./build.sh -d <oracle-7|debian-11|ubuntu-24.04> -c <gnu|clang|all> [-t tag]
```

Компилятор по умолчанию — `all` (всё, что поддерживает дистрибутив; `gcc` принимается как псевдоним `gnu`). Теги по умолчанию: `hun1er/<дистрибутив>-cxx-build-env-<компилятор>`.

| Опция | Описание |
|-------|----------|
| `-d, --distro <имя>` | Целевой дистрибутив: `oracle-7`, `debian-11`, `ubuntu-24.04` |
| `-c, --compiler <имя>` | `gnu`, `clang` или `all` (по умолчанию) |
| `-t, --tag <имя>` | Свой тег образа |
| `-h, --help` | Справка |

Порядок сборки важен. Образ Ubuntu `clang` строится поверх `hun1er/ubuntu-24.04-cxx-build-env-gnu` — сначала соберите `gnu`. Стейдж-билдер Oracle Linux 7 базируется на опубликованном образе `hun1er/oracle-7-cxx-build-env-gnu`. Сборка Oracle компилирует GCC из исходников — займёт время.

Версии инструментов живут вверху `build.sh` как переменные окружения — файлы править не нужно:

```bash
BINUTILS_VERSION=2.40 ./build.sh -d oracle-7 -c gnu -t my-tag
```

Переменные: `BINUTILS_VERSION`, `CLANG_VERSION`, `CMAKE_VERSION`, `CPPCHECK_VERSION`, `GCC_VERSION`, `MAKE_VERSION`, `NASM_VERSION`, `GOLANG_VERSION`, `OPENSSL_VERSION`.

### Сборка сторонних проектов

`csbuild.sh` принимает локальный путь или git-URL, монтирует проект в образ, определяет систему сборки и складывает бинарники в `<проект>/csbuild-out`. Порядок определения: `build.sh` проекта → AMBuild (`configure.py` + `AMBuildScript`) → `tools/linux/build.sh` → CMake (пресеты, если есть, иначе без них) → `Compile.sh`/`compile.sh` → Makefile в корне, на уровень ниже или на два уровня ниже.

```bash
./csbuild.sh /путь/к/проекту
./csbuild.sh https://github.com/Nord1cWarr1or/MatchBot
```

| Опция | Описание |
|-------|----------|
| `-o, --out <каталог>` | Базовый каталог вывода (по умолчанию: `<проект>/csbuild-out`) |
| `-b, --branch <ref>` | Ветка/тег для git-URL |
| `-i, --image <образ>` | Образ контейнера (по умолчанию: `hun1er/oracle-7-cxx-build-env-gnu:latest`) |
| `-j, --jobs <n>` | Параллельные задачи (по умолчанию: все ядра) |
| `-m, --mount <х:к>` | Дополнительный bind mount, хост:контейнер (повторяемая) |
| `-e, --env К=З` | Переменная окружения для контейнера сборки (повторяемая) |
| `-t, --target <имя>` | Собрать одну цель (`cmake --build --target` / цель make) |
| `--config <имя>` | Флейвор мульти-конфигурационных CMake-пресетов: `release` (по умолчанию), `debug`, `reldebinfo`… — выбирает соответствующий build-пресет (rehlds-m: `ninja-gcc-linux-reldebinfo`) |
| `-c, --clean` | Удалить каталог сборки перед сборкой |
| `--fresh` | Переклонировать URL-цели с нуля |
| `-n, --dry-run` | Показать определённый рецепт и выйти |
| `-- <аргументы>` | Дополнительные аргументы внутренней команде сборки |

Эпоха тулчейна выбирается автоматически. Если CI проекта объявляет `container: debian:11-slim` (так делают ReGameDLL и reapi), берётся образ Debian 11. Сборка, упавшая на современном тулчейне, один раз повторяется в образе Debian 11, прежде чем сдаться; явные `--image` или `CSBUILD_IMAGE` отключают оба поведения.

Проектам, ожидающим соседние каталоги SDK (как amxmodx), нужен маунт плюс сквозные аргументы:

```bash
git clone https://github.com/alliedmodders/metamod-hl1 metamod-am
git clone https://github.com/alliedmodders/hlsdk hlsdk
./csbuild.sh -m $PWD:/deps <путь/к/проекту> -- --metamod=/deps/metamod-am --hlsdk=/deps/hlsdk
```

Переменные окружения: `CSBUILD_IMAGE` (аналог `--image`), `CSBUILD_HOME` (каталог клонов, по умолчанию `${XDG_CACHE_HOME:-~/.cache}/csbuild/clones`).

Свои флаги сборки идут через `--` — аргументы попадают в команду конфигурирования (`cmake -DCMAKE_BUILD_TYPE=Debug`, `make CXXFLAGS=-g`, опции AMBuild `configure.py`). `-e` прокидывает переменные окружения (`CXXFLAGS`, `CFLAGS`, `LDFLAGS`), `-t` ограничивает сборку одной целью.

Прогнано пакетом по 22 проектам экосистемы: 18 собираются от начала до конца. Оставшиеся четыре не собираются по design — тулчейн под icc (ReInfoZone), сломанные апстримы (webserver_amxx, rezombie) и MSVC-only раскладка со ссылками на невендоренные репозитории (BMOD).

## Готовые образы

- [hun1er/oracle-7-cxx-build-env-gnu](https://hub.docker.com/repository/docker/hun1er/oracle-7-cxx-build-env-gnu)
- [hun1er/debian-11-cxx-build-env-gnu](https://hub.docker.com/repository/docker/hun1er/debian-11-cxx-build-env-gnu)
- [hun1er/ubuntu-24.04-cxx-build-env-gnu](https://hub.docker.com/repository/docker/hun1er/ubuntu-24.04-cxx-build-env-gnu) и [clang](https://hub.docker.com/repository/docker/hun1er/ubuntu-24.04-cxx-build-env-clang)

## Лицензия

Проект распространяется по лицензии [MIT](LICENSE).

Стороннее ПО поставляется под своими лицензиями: Oracle Linux — [Oracle Linux EULA](https://oss.oracle.com/ol7/EULA), GCC — [GNU GPL](https://gcc.gnu.org/onlinedocs/gcc/Copying.html), Clang/LLVM — [Apache 2.0 with LLVM Exceptions](https://llvm.org/docs/DeveloperPolicy.html).
