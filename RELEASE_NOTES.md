# Mirafix v1.2 — 解决投屏 / Fix stock casting / Correction du miroir d'écran

> **先读这条 / Read this first / À lire d'abord**
>
> **v1.0 在部分机型上会导致开不了机（bootloop）。请直接用 v1.2，v1.0 / v1.1 都不要再装。**
> **v1.0 could bootloop on some devices. Use v1.2; do not install v1.0 or v1.1 anymore.**
> **v1.0 pouvait empêcher le démarrage sur certains appareils. Utilisez v1.2, n'installez plus v1.0 ni v1.1.**
>
> **v1.1 本身是安全的**（签名不匹配就中止、绝不落地），但它只认字节，遇到编译器换了寄存器的构建（HyperOS 3）会装不上——v1.2 补上了这种情况。
> **v1.1 was safe** (it aborts and installs nothing when the signature does not match), but it only matched bytes, so on a build where the compiler used different registers (HyperOS 3) it could not install — v1.2 handles that case.
> **v1.1 était sûr** (il s'annule sans rien installer si la signature ne correspond pas), mais il ne comparait que des octets : sur un build où le compilateur a utilisé d'autres registres (HyperOS 3) il ne s'installait pas — v1.2 prend en charge ce cas.

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

**为什么它能适配所有澎湃系统的设备**：不是靠机型白名单，而是每次安装都从这台机器**自己的** `libsurfaceflinger.so` 里找那段指令，按证据强度逐级尝试，**每一级都必须全库唯一命中**：

1. 16 字节指令窗口（`orr|tst|csel|ret`）
2. 8 字节（`csel|ret`）
3. **语义匹配（v1.2 新增）** —— 见下
4. 最后才用 4 字节 `csel` 裸锚点（弱证据）

命中不唯一或根本找不到 → `abort`，模块不安装。**宁可不修，也不拿不确定的东西去碰系统库。**

补丁本身没变，对普通机型还是那 4 个字节：

| 文件 | 偏移 | 修改前 | 修改后 |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

换了编译器的构建里寄存器不同、偏移也不同，此时**补丁字节由命中现场推导**（`mov x{csel 目标}, x{干净来源}`），效果与上表完全等价。

### v1.2 新增：语义匹配定位器

有测试者在 **Xiaomi 17（`pudding`，HyperOS 3 / Android 16）** 上装 v1.1：三级字节签名**全部 0 命中**，安装被安全中止——手机照常开机，但投屏也没修成。原因很直接：那台机器的编译器给同一段代码分配了**不同的寄存器**，`6011889a` 这条指令在它的库里根本不存在（原版库 11.2 MB，与首发机型的 14.2 MB 也不是同一份编译产物）。

v1.2 不再只认字节：

- 先按**语义**找 `orr ?,?,#0x4000` —— `GRALLOC_USAGE_PROTECTED` 是固定的 HAL 常量 `0x4000`，任何编译器都会把它编成这一条立即数 `ORR`，**编码与寄存器分配无关**；
- 再要求 8 条指令内出现一个 `csel`，且它的两个源寄存器**恰好是这个 `orr` 的 `Ra` 和 `Rb`**——也就是「在 `usage|PROTECTED` 和 `usage` 之间二选一」这一步本身；
- 全库**唯一命中**才继续，命中 0 次或 2 次照样 `abort`。`orr x8,x8,#0x4000` 这种两个操作数相同的死形态直接排除（本机 14 MB 的库里就有 2 处 `orr #0x4000`，只有一处符合）。

安全兜底不变：装不上就中止、开机闸门逐层校验、连败 2 次自动禁用。

**自测**：强制走语义匹配重建的载荷，与实测可用的载荷**逐字节相同**（md5 `5ca0159e206fb93179b008aaa86e37d1`），并分别用 **busybox** 与 **toybox** 两套工具链跑通；30 项安装闸门测试 + 15 项开机脚本测试全绿。

**如果仍然中止**，中止信息里会打印 `orr #0x4000` 出现的位置和 `csel` 配对数，回报时把这段贴出来即可继续定位。

### 已知触发源：HyperCeiler 的截屏开关

这个 bug 不是必现的。最常见的触发源是 LSPosed 模块 **HyperCeiler（西米露）** 的「**允许在任何应用截屏**」（以及同类的 *disable flag secure* 设置）：它把 App 侧的 `FLAG_SECURE` 关了，但 `qtiSetOutputUsage` 仍然给输出 buffer 加 `GRALLOC_USAGE_PROTECTED`，于是 non-secure 编码器撞上 secure buffer → `qbuf -22` → `1008`。

- **不想装模块**：在 HyperCeiler 里关掉那个开关，投屏立刻恢复。
- **装了 Mirafix**：开关开着也能投，因为补丁让输出 buffer 永不带 `0x4000`。

### 安装

管理器 → 模块 → 本地安装 `Mirafix-v1.2.zip` → 重启

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.2.zip
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

**Why this targets every HyperOS (澎湃) device**: not through a model whitelist, but by locating the instruction in **this device's own** `libsurfaceflinger.so` on every install, trying the tiers in decreasing order of evidence — **each tier must match exactly once**:

1. 16-byte instruction window first (`orr|tst|csel|ret`),
2. then 8 bytes (`csel|ret`),
3. **the semantic matcher (new in v1.2)** — see below,
4. only then the bare 4-byte `csel` (weakest evidence).

No match, or an ambiguous one → `abort`, nothing is installed. **Better to leave the bug alone than to touch a system library with something unverified.**

The patch itself is unchanged for ordinary builds — those 4 bytes:

| File | Offset | Before | After |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

On a build produced by a different compiler the registers and the offset differ; there the **patch bytes are derived from what was actually found** (`mov x{csel dst}, x{clean source}`), which is exactly equivalent to the table above.

### New in v1.2: the semantic locator

A tester on **Xiaomi 17 (`pudding`, HyperOS 3 / Android 16)** installed v1.1: all three byte tiers found **0 matches** and the install aborted safely — the phone booted normally, but the cast bug stayed. The reason is simple: that build's compiler allocated **different registers** for the same code, so the instruction `6011889a` does not exist anywhere in its library (its stock library is 11.2 MB, not the same compile artifact as the 14.2 MB one).

v1.2 no longer relies on bytes alone:

- it first looks **semantically** for `orr ?,?,#0x4000` — `GRALLOC_USAGE_PROTECTED` is the fixed HAL constant `0x4000`, and every compiler encodes it as this single immediate `ORR`, independently of register allocation;
- it then requires a `csel` within the next 8 instructions whose two source registers are **exactly that `orr`'s `Ra` and `Rb`** — i.e. the "choose between `usage|PROTECTED` and `usage`" step itself;
- it must be **unique in the whole library**; 0 matches or 2 matches still `abort`. The dead shape `orr x8,x8,#0x4000` (both operands equal) is rejected outright — our own 14 MB library holds two `orr #0x4000` sites and only one qualifies.

The safety rails are unchanged: an install that cannot be confident aborts, the boot gate checks everything layer by layer, and two failed boots auto-disable the module.

**Self-test:** a payload rebuilt by forcing the semantic matcher is **byte-identical** to the proven payload (md5 `5ca0159e206fb93179b008aaa86e37d1`), and it runs clean under both the **busybox** and the **toybox** toolchain; 30 install-gate tests and 15 boot-script tests pass.

**If it still aborts**, the message prints where `orr #0x4000` occurs and how many `csel` pairs were seen — paste that part when reporting.

### Known trigger: HyperCeiler's screenshot switch

The bug is not always reproducible. The most common trigger is the LSPosed module **HyperCeiler**, feature **"Allow screenshots in any app"** (and similar *disable flag secure* settings): it turns `FLAG_SECURE` off on the app side while `qtiSetOutputUsage` still ORs `GRALLOC_USAGE_PROTECTED` into the output buffer, so a non-secure encoder input meets a secure buffer → `qbuf -22` → `1008`.

- **Without the module:** switch that option off in HyperCeiler and casting recovers immediately.
- **With Mirafix:** casting works with the switch on as well, because the patch makes the output buffer never carry `0x4000`.

### Install

Manager → Modules → Install from local → `Mirafix-v1.2.zip` → reboot

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.2.zip
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

**Pourquoi c'est pensé pour tous les appareils HyperOS (澎湃)** : non par une liste blanche de modèles, mais en localisant l'instruction dans **la bibliothèque propre à l'appareil** à chaque installation, en essayant les niveaux par ordre de preuve décroissante — **chaque niveau doit correspondre une seule fois** :

1. fenêtre d'instruction de 16 octets (`orr|tst|csel|ret`),
2. puis 8 octets (`csel|ret`),
3. **le localisateur sémantique (nouveau dans v1.2)** — voir ci-dessous,
4. enfin le simple `csel` de 4 octets (preuve la plus faible).

Pas de correspondance, ou correspondance ambiguë → `abort`, rien n'est installé. **Mieux vaut laisser le bug tranquille que de toucher une bibliothèque système avec du non vérifié.**

Le correctif, lui, n'a pas changé pour les builds standards — ces 4 octets :

| Fichier | Offset | Avant | Après |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

Sur un build produit par un autre compilateur, les registres et l'offset diffèrent ; là, **les octets du correctif sont déduits de ce qui a réellement été trouvé** (`mov x{dst du csel}, x{source propre}`), ce qui est strictement équivalent au tableau ci-dessus.

### Nouveau dans v1.2 : le localisateur sémantique

Un testeur sur **Xiaomi 17 (`pudding`, HyperOS 3 / Android 16)** a installé v1.1 : les trois niveaux par octets ont trouvé **0 correspondance**, l'installation s'est annulée en toute sécurité — le téléphone a démarré normalement, mais le bug de projection restait. La raison est simple : le compilateur de ce build a attribué **d'autres registres** au même code, donc l'instruction `6011889a` n'existe nulle part dans sa bibliothèque (11,2 Mo en stock, ce n'est pas le même artefact de compilation que les 14,2 Mo).

v1.2 ne s'appuie plus seulement sur des octets :

- il cherche d'abord **sémantiquement** `orr ?,?,#0x4000` — `GRALLOC_USAGE_PROTECTED` est la constante HAL fixe `0x4000`, et tout compilateur l'encode en cet `ORR` immédiat unique, quelle que soit l'attribution des registres ;
- il exige ensuite un `csel` dans les 8 instructions suivantes dont les deux registres sources sont **exactement le `Ra` / le `Rb` de ce `orr`** — c'est-à-dire l'étape « choisir entre `usage|PROTECTED` et `usage` » elle-même ;
- il doit être **unique dans toute la bibliothèque** ; 0 ou 2 correspondances → `abort`. La forme morte `orr x8,x8,#0x4000` (deux opérandes identiques) est écartée d'emblée — notre propre bibliothèque de 14 Mo contient deux sites `orr #0x4000` dont un seul convient.

Les sécurités restent inchangées : une installation qui n'est pas sûre s'annule, la barrière de démarrage vérifie tout couche par couche, et deux échecs consécutifs désactivent le module.

**Auto-test :** une charge utile reconstruite en forçant le localisateur sémantique est **identique octet à octet** à la charge validée (md5 `5ca0159e206fb93179b008aaa86e37d1`), et passe sous les deux chaînes d'outils **busybox** et **toybox** ; les 30 tests de barrière d'installation et les 15 tests de scripts de démarrage passent.

**Si l'annulation persiste**, le message indique où se trouve `orr #0x4000` et combien de paires `csel` ont été vues — collez cette partie en cas de signalement.

### Déclencheur connu : l'option capture d'écran d'HyperCeiler

Le bug n'est pas toujours reproductible. Le déclencheur le plus fréquent est le module LSPosed **HyperCeiler**, fonction **« Autoriser la capture d'écran dans toutes les applications »** (et les options du type *désactiver FLAG_SECURE*) : elle coupe `FLAG_SECURE` côté application pendant que `qtiSetOutputUsage` continue d'ajouter `GRALLOC_USAGE_PROTECTED` au buffer de sortie — entrée d'encodeur non sécurisée contre buffer secure → `qbuf -22` → `1008`.

- **Sans le module :** désactivez cette option dans HyperCeiler et la projection revient immédiatement.
- **Avec Mirafix :** la projection fonctionne même avec l'option active, car le correctif fait que le buffer de sortie ne porte jamais `0x4000`.

### Installation

Gestionnaire → Modules → Installer depuis un fichier local → `Mirafix-v1.2.zip` → redémarrage

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.2.zip
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

- `Mirafix-v1.2.zip` — 模块包，管理器直接安装 / module package, install it straight from the manager / paquet de module, à installer depuis le gestionnaire.
- Zip 里**不含任何预编译库**；载荷由安装脚本从本机库现场生成 / The zip ships **no pre-built library**; the payload is generated by the installer from the local one / L'archive **ne contient aucune bibliothèque précompilée** ; la charge utile est produite par l'installateur à partir de la locale.

### ✅ 要求 / Requirements / Prérequis

- Root: **Magisk (official / Alpha), KernelSU, ReZukisu**
- 测试机型 / Tested on / Testé sur: **Xiaomi 17 Pro / HyperOS 4**
- 系统侧 4 字节改动，**不动接收端、不用第三方投屏 App** / 4 bytes on the system side, sink untouched, no third-party casting app / 4 octets côté système, récepteur inchangé, aucune app tierce

### 🛟 万一开不了机 / If it won't boot / Si le téléphone ne démarre pas

开机动画时**长按音量下键** → 安全模式 → 移除模块 → 重启 / **Hold volume down** during the boot animation → safe mode → remove the module → reboot / **Maintenez volume bas** pendant l'animation → mode de sécurité → retirez le module → redémarrez
