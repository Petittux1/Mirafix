# Mirafix v1.1 — 解决投屏 / Fix stock casting / Correction du miroir d'écran

> **先读这条 / Read this first / À lire d'abord**
>
> **v1.0 在部分机型上会导致开不了机（bootloop）。v1.1 已经彻底重构，请勿再使用 v1.0。**
> **v1.0 could bootloop on some devices. v1.1 is a full rework — do not use v1.0 anymore.**
> **v1.0 pouvait empêcher le démarrage sur certains appareils. v1.1 est une refonte complète — n'utilisez plus v1.0.**

---

## 中文

### v1.0 为什么会开不了机

v1.0 的 zip 里**带着一份预编译好的 14MB `libsurfaceflinger.so`**——那是从**作者自己的机器**上抠下来的。装到**别的系统版本**上，就等于把一个不属于这台机器的库塞进 `surfaceflinger` 的加载路径，SF 起不来，连崩 4 次触发看门狗，整机反复重启。

v1.1 换掉了整个思路：**zip 里不含任何二进制**，安装时读取**本机自己的**库、现场打补丁。

### v1.1 改了什么

| | v1.0 | v1.1 |
|---|---|---|
| 载荷来源 | zip 里预编译的库（作者机型的） | **安装时从本机库现场生成** |
| 机型/系统适配 | 靠作者那一份，其它机型不保证 | **签名自适应**：现场定位指令，唯一命中才装 |
| 不适用的设备 | 照样装上去 → 可能开不了机 | **安装直接中止**，模块不落地，开机与出厂一致 |
| root 兼容 | 实测 KernelSU / ReZukisu | **Magisk（含 Alpha）、KernelSU、ReZukisu** |
| 挂载方式 | 模块自动挂载（magic mount） | `skip_mount` + 脚本接管，三套 root 同一套逻辑 |
| 开机异常自愈 | 无 | **上次开机没走完 → 下次绝不绑定**；连续 2 次自动禁用 |
| OTA 之后 | 可能拿旧载荷碰新系统 | **身份指纹对不上 → 自动禁用并写日志**，需要重装 |
| 诊断 | 需要终端看日志 | 管理器里 **Action** 按钮直接输出诊断 |

**为什么它能适配所有澎湃系统的设备**：不是靠机型白名单，而是每次安装都从这台机器**自己的** `libsurfaceflinger.so` 里找那段指令——

1. 优先 16 字节指令窗口（`orr|tst|csel|ret`）
2. 找不到就退到 8 字节（`csel|ret`）
3. 再不行退到 4 字节 `csel`，但**必须全库唯一命中**

命中不唯一或根本找不到 → `abort`，模块不安装。**宁可不修，也不拿不确定的东西去碰系统库。**

补丁本身没变，还是那 4 个字节：

| 文件 | 偏移 | 修改前 | 修改后 |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

### 已知触发源：HyperCeiler 的截屏开关

这个 bug 不是必现的。最常见的触发源是 LSPosed 模块 **HyperCeiler（西米露）** 的「**允许在任何应用截屏**」（以及同类的 *disable flag secure* 设置）：它把 App 侧的 `FLAG_SECURE` 关了，但 `qtiSetOutputUsage` 仍然给输出 buffer 加 `GRALLOC_USAGE_PROTECTED`，于是 non-secure 编码器撞上 secure buffer → `qbuf -22` → `1008`。

- **不想装模块**：在 HyperCeiler 里关掉那个开关，投屏立刻恢复。
- **装了 Mirafix**：开关开着也能投，因为补丁让输出 buffer 永不带 `0x4000`。

### 安装

管理器 → 模块 → 本地安装 `Mirafix-v1.1.zip` → 重启

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.1.zip
reboot
```

Magisk / Alpha：Magisk 应用 → 模块 → 从本地安装 → 重启。

安装时会打印本机身份、原版 md5、补丁偏移、生成载荷的 md5，**对不上就直接中止**。

### 出问题怎么办

- **诊断**：管理器 → 模块 → Mirafix → **Action**，把输出整段发出来；或直接给 `/data/adb/mirafix.log`（只有机型 / 系统版本 / md5 / 偏移，**无任何个人信息**）。
- **临时禁用**：

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

- **开不了机**：开机动画出现时**长按音量下键**进 Android 安全模式（Magisk 与 KernelSU 都会因此停用所有模块），进去后移除模块，再正常重启。

### 要求

- Root: **Magisk（官方 / Alpha）、KernelSU、ReZukisu**
- 所有澎湃（HyperOS）设备设计目标；不适用的构建会在安装期中止
- 系统侧 4 字节改动，**不动接收端、不用第三方投屏 App**

---

## English

### Why v1.0 could bootloop

The v1.0 zip **shipped a pre-built 14 MB `libsurfaceflinger.so`** — the one scraped off the **author's own device**. Installed on a **different OS build**, it put a foreign library into `surfaceflinger`'s load path, SF never comes up, dies 4 times and the watchdog reboots the phone in a loop.

v1.1 inverts the whole approach: **the zip contains no binary at all**; the payload is generated from **this device's own** library at install time.

### What changed in v1.1

| | v1.0 | v1.1 |
|---|---|---|
| Payload source | pre-built library from the zip | **built on-device at install time** |
| Model / OS adaptation | whatever the author's device had | **signature auto-adaptive**: the instruction is located on the spot, install requires a unique match |
| Unsupported device | installed anyway → can bootloop | **install aborts**, the module never lands, phone boots as from the factory |
| Root support | tested KernelSU / ReZukisu | **Magisk (incl. Alpha), KernelSU, ReZukisu** |
| Mounting | automatic module mounting (magic mount) | `skip_mount` + script-controlled, identical logic on all three roots |
| Self-heal after a bad boot | none | **if a boot never finished, the next one never binds**; two in a row auto-disable the module |
| After an OTA | could push the old payload onto a new system | **identity mismatch → auto-disable + log**, reinstall required |
| Diagnostics | needed a terminal to read the log | one tap on **Action** in the manager |

**Why this targets every HyperOS (澎湃) device**: not through a model whitelist, but by locating the instruction in **this device's own** `libsurfaceflinger.so` on every install —

1. 16-byte instruction window first (`orr|tst|csel|ret`),
2. fall back to 8 bytes (`csel|ret`),
3. then to the bare 4-byte `csel`, but it **must be unique in the whole library**.

No match, or an ambiguous one → `abort`, nothing is installed. **Better to leave the bug alone than to touch a system library with something unverified.**

The patch itself is unchanged — those 4 bytes:

| File | Offset | Before | After |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

### Known trigger: HyperCeiler's screenshot switch

The bug is not always reproducible. The most common trigger is the LSPosed module **HyperCeiler**, feature **"Allow screenshots in any app"** (and similar *disable flag secure* settings): it turns `FLAG_SECURE` off on the app side while `qtiSetOutputUsage` still ORs `GRALLOC_USAGE_PROTECTED` into the output buffer, so a non-secure encoder input meets a secure buffer → `qbuf -22` → `1008`.

- **Without the module:** switch that option off in HyperCeiler and casting recovers immediately.
- **With Mirafix:** casting works with the switch on as well, because the patch makes the output buffer never carry `0x4000`.

### Install

Manager → Modules → Install from local → `Mirafix-v1.1.zip` → reboot

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.1.zip
reboot
```

Magisk / Alpha: Magisk app → Modules → Install from local → reboot.

The installer prints your device identity, the stock md5, the patch offset and the generated payload md5 — and **aborts if anything does not add up**.

### If something goes wrong

- **Diagnostics:** Manager → Modules → Mirafix → **Action**, copy the whole output; or just send `/data/adb/mirafix.log` (model / OS version / md5 / offset only — **no personal data**).
- **Temporarily disable:**

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

- **Phone won't boot:** **hold volume down while the boot animation is showing** to enter Android safe mode (both Magisk and KernelSU disable all modules there), remove the module, then reboot normally.

### Requirements

- Root: **Magisk (official / Alpha), KernelSU, ReZukisu**
- Target: all HyperOS (澎湃) devices; builds where the signature cannot be uniquely found abort at install time
- 4 bytes on the system side — **sink untouched, no third-party casting app**

---

## Français

### Pourquoi v1.0 pouvait empêcher le démarrage

L'archive v1.0 **embarquait une bibliothèque `libsurfaceflinger.so` précompilée de 14 Mo**, extraite de **l'appareil de l'auteur**. Installée sur une **autre version du système**, elle plaquait une bibliothèque étrangère dans le chemin de chargement de `surfaceflinger` : SF ne démarre pas, meurt 4 fois, le watchdog redémarre le téléphone en boucle.

v1.1 inverse tout l'approche : **l'archive ne contient aucun binaire** ; la charge utile est produite à partir de **la bibliothèque propre à l'appareil**, à l'installation.

### Ce qui change en v1.1

| | v1.0 | v1.1 |
|---|---|---|
| Origine de la charge utile | bibliothèque précompilée dans l'archive | **produite sur l'appareil à l'installation** |
| Adaptation modèle / système | celle de l'appareil de l'auteur | **signature auto-adaptative** : instruction localisée sur place, installation sous condition d'unicité |
| Appareil non pris en charge | installé quand même → démarrage possible bloqué | **installation annulée**, le module ne se dépose jamais, le téléphone démarre comme en usine |
| Compatibilité root | testé KernelSU / ReZukisu | **Magisk (dont Alpha), KernelSU, ReZukisu** |
| Montage | montage automatique du module (magic mount) | `skip_mount` + pilotage par scripts, même logique sur les trois roots |
| Auto-réparation après un mauvais boot | aucune | **si un boot n'a pas abouti, le suivant ne monte rien** ; deux de suite → désactivation automatique |
| Après une OTA | charge utile ancienne poussée sur un système nouveau | **identité non conforme → désactivation + log**, réinstallation requise |
| Diagnostic | terminal nécessaire pour lire le log | un appui sur **Action** dans le gestionnaire |

**Pourquoi c'est pensé pour tous les appareils HyperOS (澎湃)** : non par une liste blanche de modèles, mais en localisant l'instruction dans **la bibliothèque propre à l'appareil** à chaque installation —

1. fenêtre d'instruction de 16 octets (`orr|tst|csel|ret`),
2. repli sur 8 octets (`csel|ret`),
3. puis sur le simple `csel` de 4 octets, à condition qu'il soit **unique dans toute la bibliothèque**.

Pas de correspondance, ou correspondance ambiguë → `abort`, rien n'est installé. **Mieux vaut laisser le bug tranquille que de toucher une bibliothèque système avec du non vérifié.**

Le correctif, lui, n'a pas changé — ces 4 octets :

| Fichier | Offset | Avant | Après |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

### Déclencheur connu : l'option capture d'écran d'HyperCeiler

Le bug n'est pas toujours reproductible. Le déclencheur le plus fréquent est le module LSPosed **HyperCeiler**, fonction **« Autoriser la capture d'écran dans toutes les applications »** (et les options du type *désactiver FLAG_SECURE*) : elle coupe `FLAG_SECURE` côté application pendant que `qtiSetOutputUsage` continue d'ajouter `GRALLOC_USAGE_PROTECTED` au buffer de sortie — entrée d'encodeur non sécurisée contre buffer secure → `qbuf -22` → `1008`.

- **Sans le module :** désactivez cette option dans HyperCeiler et la projection revient immédiatement.
- **Avec Mirafix :** la projection fonctionne même avec l'option active, car le correctif fait que le buffer de sortie ne porte jamais `0x4000`.

### Installation

Gestionnaire → Modules → Installer depuis un fichier local → `Mirafix-v1.1.zip` → redémarrage

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.1.zip
reboot
```

Magisk / Alpha : app Magisk → Modules → Installer depuis un fichier local → redémarrage.

L'installateur affiche l'identité de l'appareil, le md5 d'origine, l'offset du correctif et le md5 de la charge utile générée — et **s'arrête si quelque chose ne colle pas**.

### En cas de problème

- **Diagnostic :** Gestionnaire → Modules → Mirafix → **Action**, copiez toute la sortie ; ou envoyez simplement `/data/adb/mirafix.log` (modèle / version système / md5 / offset uniquement — **aucune donnée personnelle**).
- **Désactivation temporaire :**

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

- **Démarrage bloqué :** **maintenez volume bas pendant l'animation de démarrage** pour entrer en mode de sécurité Android (Magisk et KernelSU y désactivent tous les modules), retirez le module, puis redémarrez normalement.

### Prérequis

- Root : **Magisk (officiel / Alpha), KernelSU, ReZukisu**
- Cible : tous les appareils HyperOS (澎湃) ; les builds où la signature n'est pas trouvée de façon unique annulent l'installation
- 4 octets côté système — **récepteur inchangé, aucune application de projection tierce**

---

### 🔒 DRM 说明 / DRM note / Note DRM

补丁只作用于**虚拟显示器（投屏）输出路径**，本机 DRM 播放不受影响，Mirafix **不绕过任何 DRM**；投 DRM 内容可能黑屏属正常行为。/ The patch only touches the **virtual display (cast) output path**, local DRM playback is unaffected and Mirafix **does not bypass DRM**; casting DRM content may show a black picture, which is normal behaviour. / Le correctif ne touche que le **chemin de sortie de l'affichage virtuel (projection)**, la lecture DRM locale n'est pas affectée et Mirafix **ne contourne aucun DRM** ; projeter du contenu DRM peut donner une image noire, comportement normal.

### 📦 Fichier / Asset

- `Mirafix-v1.1.zip` — 模块包，管理器直接安装 / module package, install it straight from the manager / paquet de module, à installer depuis le gestionnaire.
- Zip 里**不含任何预编译库**；载荷由安装脚本从本机库现场生成 / The zip ships **no pre-built library**; the payload is generated by the installer from the local one / L'archive **ne contient aucune bibliothèque précompilée** ; la charge utile est produite par l'installateur à partir de la locale.

### ✅ 要求 / Requirements / Prérequis

- Root: **Magisk (official / Alpha), KernelSU, ReZukisu**
- 测试机型 / Tested on / Testé sur: **Xiaomi 17 Pro / HyperOS 4**
- 系统侧 4 字节改动，**不动接收端、不用第三方投屏 App** / 4 bytes on the system side, sink untouched, no third-party casting app / 4 octets côté système, récepteur inchangé, aucune app tierce

### 🛟 万一开不了机 / If it won't boot / Si le téléphone ne démarre pas

开机动画时**长按音量下键** → 安全模式 → 移除模块 → 重启 / **Hold volume down** during the boot animation → safe mode → remove the module → reboot / **Maintenez volume bas** pendant l'animation → mode de sécurité → retirez le module → redémarrez
