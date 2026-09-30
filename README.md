# Mirafix — 解决投屏

[English](#english) · [中文](#中文) · [Français](#français)

修复小米 / HyperOS **原生投屏**（Miracast / WFD）连接**非小米显示器**时失败的问题。
Fixes **stock** Miracast / WFD casting from Xiaomi / HyperOS to **non-Xiaomi displays**.
Corrige le miroir d'écran **d'origine** (Miracast / WFD) de Xiaomi / HyperOS vers un **écran non Xiaomi**.

**当前版本 / Current release: `v1.1`**

---

## 中文

### 症状

用系统自带的投屏连非小米的无线显示器（Newlink、EZCast 等）时，连接建立后立刻失败，日志里是这样一条链：

```
secure buffer mapping to non-secure region 8 not allowed
failed to attach. INPUT: NON_SECURE_PIXEL: idx 0 size 3219456
msm_vidc_qbuf: failed with -22
setCurWfdErrorCode=1008
```

最终表现就是投屏界面报 **错误 1008**，画面出不来。
恢复出厂设置、换机、换显示器都没用——因为问题在 `surfaceflinger` 的代码里，不在设备数据里。

### 根因

`QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage(unsigned long)` 里有一条：

```asm
5b9ba0: orr  x11, x8, #0x4000        ; 0x4000 = GRALLOC_USAGE_PROTECTED
5b9ba4: tst  w10, w9
5b9ba8: csel x0, x11, x8, ne          ; ← 问题在这
5b9bac: ret
```

它会给显示输出 buffer 加上 **`GRALLOC_USAGE_PROTECTED`**，于是 gralloc 把 buffer 分配在 secure heap 里。而编码器输入端要求 non-secure，`msm_vb2_attach_dmabuf` 直接拒绝 → `qbuf -22` → `1008`。

**这是整个 `libsurfaceflinger.so` 里唯一一处**给显示链路加保护位的指令（另一处 `#0x4000` 在 Skia 的 `GrGLExtensions` 里，无关）。

### 已知触发源：HyperCeiler 的截屏开关

这个 bug 不是必现的，实测最常见的**触发源**是 LSPosed 模块 **HyperCeiler（西米露）** 里的

> 「允许在任何应用截屏」（以及同类的 *disable FLAG_SECURE* 设置）

这类开关会把 App 侧的 `FLAG_SECURE` 关掉，但 `qtiSetOutputUsage` 仍然给输出 buffer OR 上 `GRALLOC_USAGE_PROTECTED`——于是一边是 non-secure 编码器输入、一边是 secure buffer，撞出上面那条 `qbuf -22`。

- **临时绕过**：在 HyperCeiler 里关掉「允许在任何应用截屏」/ disable-flag-secure 相关项，重启投屏即恢复，不用刷任何东西。
- **彻底修复**：装 Mirafix。补丁直接让输出 buffer 永不带 `0x4000`，无论那个开关是否打开都能投屏。

### 补丁

把 4 个字节换掉，让它永远走「不加保护位」的分支：

| 位置 | 原指令 | 补丁后 |
|---|---|---|
| `libsurfaceflinger.so` `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

净效果：输出 buffer 永远不带 `0x4000`，不再落 secure heap，编码器正常接收。

### 要求与兼容性

- **root**：Magisk（官方 / Alpha）、KernelSU、ReZukisu。挂载由脚本接管（`skip_mount`），三套 root 走同一套逻辑。
- **机型 / 系统**：面向**所有澎湃（HyperOS）系统**的设备设计，不靠机型白名单。
- 安装时模块会**读取本机自己的 `libsurfaceflinger.so`**，在现场定位目标指令（16 字节窗口 → 8 字节 `csel+ret` → 4 字节 `csel` 三级匹配，**必须唯一命中**），然后生成补丁载荷。
  - 命中 → 生成载荷，校验通过后安装成功，重启生效。
  - **0 命中 / 命中不唯一 / 读不到原版 → 安装直接中止**，模块不会留在手机上，开机与出厂状态无异。
- 只改系统侧，**不改投影接收端、不装任何第三方投屏 App**。
- 模块自带**身份指纹**（机型 + `ro.build.fingerprint`）。OTA 升级后身份对不上会**自动禁用**并写日志，需要重新安装——不会拿旧系统的载荷去碰新系统。

### 安装

方式一（推荐）：管理器 → 模块 → 从本地安装 `Mirafix-v1.1.zip` → 重启。

方式二：命令行

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.1.zip
reboot
```

Magisk / Alpha 同理：Magisk 管理器 → 模块 → 从本地安装 → 重启。

### 工作方式与安全兜底

zip 里**不带任何预编译二进制**，载荷是安装时从本机库现场生成的。模块目录里有 `skip_mount`，所以自动挂载被关掉，挂载完全由脚本控制。

**开机闸门（`post-fs-data.sh`，任何一步不过就整段放弃，不影响开机）：**

1. 上次启动没走完（`.boot_state` 还是 `pending`）→ **这次绝不绑定**，用原版库开机；连续 2 次 → 自动写 `disable` 自我禁用。
2. 身份校验：`ro.build.fingerprint`、`ro.product.model` 与 `build.info` 记录不一致 → 跳过并禁用。
3. 载荷校验：md5 与安装记录不符 / 权限不是 `0644`（会先自愈一次）/ SELinux 上下文不是 `system_lib_file` 或 `system_file` / 补丁 4 字节不对 → 全部跳过。
4. 全部通过 → 先写 `pending`，再用 `nsenter -t 1 -m mount --bind` 绑定，并**读回 init 视角的 4 字节确认**，之后才让 `surfaceflinger` 起来。

**`service.sh`（late_start）：** 按 **inode**（不是路径——lazy unmount 后内核会把 maps 路径渲染成 `/`）确认 SF 真的加载了补丁库；没加载最多重启 SF 2 次，每次重启前都重查载荷 `0644` + SELinux 上下文，SF 起不来立刻 `umount -l` 回滚原版，并把状态留在 `pending` 让下次开机保护性跳过。稳定后清零重试计数。

> ⚠️ 载荷必须是 `0644` + `u:object_r:system_lib_file:s0`（与原文件一致）。若是 `0600` 或 `app_data_file`，`surfaceflinger`（uid 1000）`dlopen` 失败，连崩 4 次会触发看门狗**整机重启**。这一步装机和开机都强制校验，过不了就不挂载。

### DRM 说明

补丁只作用于 **虚拟显示器（投屏）输出路径**，本机播放受保护视频不受影响，Mirafix **也不绕过任何 DRM**。把受 DRM 保护的内容投出去时画面可能是黑的，这是 DRM 的正常行为，不是本模块的缺陷。

### 出问题怎么自查 / 回报

模块自带诊断按钮，**不用终端**：

1. 管理器 → 模块 → Mirafix → **Action**
2. 把输出整段复制出来发给我

或者直接把 `/data/adb/mirafix.log` 发出来（里面只有机型 / 系统版本 / md5 / 偏移量，**没有序列号、IMEI、MAC、账号等任何个人信息**）。

日志里关键行的含义：

| 日志 | 含义 |
|---|---|
| `已绑定载荷 offset=...` | 本次开机补丁已生效 |
| `上次启动未走完(pending)...保护性跳过` | 上次开机出过问题，这次自动改用原版保命 |
| `连续 2 次启动异常，已自动禁用模块` | 模块已自我禁用，需在管理器里重新启用并重装 |
| `系统指纹已变化（OTA？）...需重新安装` | 系统升级过，重装一次即可 |
| `签名未找到 / 匹配不唯一`（安装时） | 本机型/系统不适用，安装已中止 |

### 自救（万一开不了机）

开机时进入**安全模式**，模块就不会被加载：

1. 关机后开机，**在开机动画出现时长按音量下键**（Android 官方安全模式，会提示 "安全模式"）。
2. Magisk：安全模式下 Magisk 会停用所有模块；KernelSU / ReZukisu 检测到 `ro.sys.safemode` 后会跳过所有模块脚本并禁用模块。
3. 进系统后在管理器里移除或禁用 Mirafix，再正常重启。

正常情况下**用不到这一步**：v1.1 的 `skip_mount` + 闸门脚本任何异常都只做一件事——不挂载、用原版库开机。

### 卸载 / 回滚

临时禁用：

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

彻底卸载：管理器里移除模块后重启，或删除 `/data/adb/modules/mirafix` 后重启。系统分区本身从未被修改，重启即回到出厂状态。

### 致谢与声明

- 逆向与验证全部在本机完成，补丁仅 4 字节。
- 仅供学习研究；刷入前请自行备份。
- 作者：**Petittux** · GitHub：**Petittux1**

---

## English

### Symptom

When casting with the **stock** system app to a **non-Xiaomi** wireless display (Newlink, EZCast, …), the session is established and then immediately fails with this chain:

```
secure buffer mapping to non-secure region 8 not allowed
failed to attach. INPUT: NON_SECURE_PIXEL: idx 0 size 3219456
msm_vidc_qbuf: failed with -22
setCurWfdErrorCode=1008
```

The UI ends up showing **error 1008** and no picture. Factory reset, another phone, another display — none of it helps, because the bug lives in the `surfaceflinger` code, not in device data.

### Root cause

In `QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage(unsigned long)`:

```asm
5b9ba0: orr  x11, x8, #0x4000        ; 0x4000 = GRALLOC_USAGE_PROTECTED
5b9ba4: tst  w10, w9
5b9ba8: csel x0, x11, x8, ne          ; <-- the culprit
5b9bac: ret
```

It ORs **`GRALLOC_USAGE_PROTECTED`** into the display output buffer usage, so gralloc allocates the buffer on the **secure heap**. The encoder input side requires non-secure buffers, `msm_vb2_attach_dmabuf` rejects them → `qbuf -22` → `1008`.

This is the **only** instruction in the whole `libsurfaceflinger.so` that adds the protection bit on the display path (the other `#0x4000` lives in Skia's `GrGLExtensions` and is unrelated).

### Known trigger: HyperCeiler's screenshot switch

The bug is not always reproducible. The most common **trigger** found in practice is the LSPosed module **HyperCeiler**:

> "Allow screenshots in any app" (and other *disable FLAG_SECURE* settings)

Such switches turn `FLAG_SECURE` off on the app side, while `qtiSetOutputUsage` still ORs `GRALLOC_USAGE_PROTECTED` into the output buffer — so you end up with a non-secure encoder input against a secure buffer, producing the `qbuf -22` above.

- **Temporary workaround:** switch "Allow screenshots in any app" / the disable-flag-secure option **off** in HyperCeiler and retry casting. Nothing gets flashed.
- **Permanent fix:** install Mirafix. The patch makes the output buffer never carry `0x4000`, so casting works whether or not that switch is on.

### The patch

Four bytes, forcing the "never protected" branch:

| File | Offset | Before | After |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

Net effect: output buffers never carry `0x4000`, they stay non-secure, and the encoder accepts them.

### Requirements & compatibility

- **Root:** Magisk (official / Alpha), KernelSU, ReZukisu. Mounting is script-driven (`skip_mount`), so all three behave the same way.
- **Device / OS:** designed for **every HyperOS (澎湃) device** — no model whitelist.
- At install time the module **reads this device's own `libsurfaceflinger.so`** and locates the target instruction on the spot (16-byte window → 8-byte `csel+ret` → 4-byte `csel`, three tiers, and it **must match exactly once**), then builds the payload:
  - matched → payload generated and verified, install succeeds, effective after reboot;
  - **0 matches / more than one match / pristine file unreadable → the install aborts** and the module is never left on the phone, so the phone boots exactly as it did from the factory.
- System side only — **the sink is untouched, no third-party casting app is used**.
- The module records an **identity fingerprint** (model + `ro.build.fingerprint`). After an OTA the identity no longer matches, so the module **disables itself** and writes a log line — it will never push a payload built for the old system onto a new one.

### Install

Recommended: manager → Modules → Install from local → `Mirafix-v1.1.zip` → reboot.

Or from a shell:

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.1.zip
reboot
```

Same thing in Magisk / Alpha: Magisk app → Modules → Install from local → reboot.

### How it works, and the safety rails

The zip ships **no prebuilt binary** — the payload is generated on-device at install time. The module directory contains a `skip_mount` file, so automatic mounting is disabled and the scripts control all mounting.

**Boot gate (`post-fs-data.sh`; any failed step abandons the whole thing and never blocks boot):**

1. Previous boot never finished (`.boot_state` still `pending`) → **never bind this time**, boot with the library; twice in a row → writes `disable` and turns itself off.
2. Identity: `ro.build.fingerprint` / `ro.product.model` differ from `build.info` → skip and disable.
3. Payload: md5 differs from the install record / mode is not `0644` (it self-heals once first) / SELinux type is neither `system_lib_file` nor `system_file` / the 4 patched bytes are wrong → all skipped.
4. Everything passes → write `pending`, bind with `nsenter -t 1 -m mount --bind`, then **read the 4 bytes back from init's view** to confirm before `surfaceflinger` is allowed to start.

**`service.sh` (late_start):** confirms by **inode**, not path (after a lazy unmount the kernel renders the maps path as `/`), that SF really mapped the payload; if not, it restarts SF at most twice, re-checking `0644` + SELinux type before every restart, and `umount -l`s back to stock immediately if SF cannot come up, leaving the state `pending` so the next boot skips protectively. The retry counter is cleared once SF is stable.

> ⚠️ The payload must be `0644` with SELinux type `u:object_r:system_lib_file:s0` (identical to the original file). With `0600` or `app_data_file`, `surfaceflinger` (uid 1000) cannot `dlopen` it, dies 4 times in a minute and the watchdog **reboots the phone**. Both are enforced at install time and again at boot; if either check fails, nothing gets mounted.

### DRM note

The patch only affects the **virtual display (cast) output path**, so local DRM playback is unaffected, and Mirafix **does not bypass DRM**. Casting DRM-protected content may show a black picture — that is normal DRM behaviour, not a defect of this module.

### Troubleshooting / reporting

The module ships a diagnostics button — **no terminal needed**:

1. Manager → Modules → Mirafix → **Action**
2. Copy the whole output and send it over.

Or just share `/data/adb/mirafix.log` (it only contains model / OS version / md5 / offset — **no serial number, IMEI, MAC, account or any other personal data**).

What the key log lines mean:

| Log line | Meaning |
|---|---|
| `已绑定载荷 offset=...` | Patch is active for this boot |
| `上次启动未走完(pending)...保护性跳过` | Last boot went wrong; this one fell back to stock to stay safe |
| `连续 2 次启动异常，已自动禁用模块` | The module disabled itself — re-enable and reinstall |
| `系统指纹已变化（OTA？）...需重新安装` | System was updated; just reinstall |
| `signature not found / matched N places` (at install) | This build is not supported; the install aborted |

### Recovery (if the phone ever fails to boot)

Enter **safe mode** so no module loads:

1. Power off, then power on and **hold volume down while the boot animation is showing** (stock Android safe mode; a "Safe mode" badge appears).
2. Magisk disables all modules in safe mode; KernelSU / ReZukisu detects `ro.sys.safemode` and skips every module script while disabling all modules.
3. Remove or disable Mirafix in the manager, then reboot normally.

You should not need this with v1.1: `skip_mount` plus the gate scripts mean that **any** failure results in nothing being mounted and the phone booting with the stock library.

### Uninstall / rollback

Temporarily disable:

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

Full uninstall: remove the module in the manager (or delete `/data/adb/modules/mirafix`) and reboot. The system partition itself is never modified — a reboot returns everything to factory state.

### Credits & disclaimer

- All reversing and verification was done on-device; the patch is 4 bytes.
- For study and research only; back up before flashing.
- Author: **Petittux** · GitHub: **Petittux1**

---

## Français

### Symptôme

Lors du miroir d'écran **d'origine** vers un écran sans fil **non Xiaomi** (Newlink, EZCast, …), la session s'établit puis échoue immédiatement :

```
secure buffer mapping to non-secure region 8 not allowed
failed to attach. INPUT: NON_SECURE_PIXEL: idx 0 size 3219456
msm_vidc_qbuf: failed with -22
setCurWfdErrorCode=1008
```

L'interface affiche l'**erreur 1008** et aucune image. Réinitialisation d'usine, autre téléphone, autre écran : rien n'aide, car le bug est dans le code de `surfaceflinger`, pas dans les données de l'appareil.

### Cause

Dans `QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage(unsigned long)` :

```asm
5b9ba0: orr  x11, x8, #0x4000        ; 0x4000 = GRALLOC_USAGE_PROTECTED
5b9ba4: tst  w10, w9
5b9ba8: csel x0, x11, x8, ne          ; ← le coupable
5b9bac: ret
```

Le drapeau **`GRALLOC_USAGE_PROTECTED`** est ajouté à l'usage des buffers de sortie, ce qui fait allouer ceux-ci sur le **heap secure**. Le côté entrée de l'encodeur exige du non-sécurisé, `msm_vb2_attach_dmabuf` refuse → `qbuf -22` → `1008`.

C'est la **seule** instruction de tout `libsurfaceflinger.so` qui ajoute ce bit sur le chemin d'affichage (l'autre `#0x4000` se trouve dans `GrGLExtensions` de Skia, sans rapport).

### Déclencheur connu : l'option capture d'écran d'HyperCeiler

Le bug n'est pas toujours reproductible. Le **déclencheur** le plus fréquent est le module LSPosed **HyperCeiler** :

> « Autoriser la capture d'écran dans toutes les applications » (et les options du type *désactiver FLAG_SECURE*)

Ces options coupent `FLAG_SECURE` côté application, alors que `qtiSetOutputUsage` continue d'ajouter `GRALLOC_USAGE_PROTECTED` au buffer de sortie : on obtient une entrée d'encodeur non sécurisée face à un buffer secure, d'où le `qbuf -22` ci-dessus.

- **Contournement temporaire :** désactivez « Autoriser la capture d'écran… » / l'option désactivant FLAG_SECURE dans HyperCeiler, puis relancez la projection. Rien n'est flashé.
- **Correction définitive :** installez Mirafix. Le correctif fait que le buffer de sortie ne porte jamais `0x4000`, la projection fonctionne donc que cette option soit activée ou non.

### Le correctif

Quatre octets, en forçant la branche « jamais protégé » :

| Fichier | Offset | Avant | Après |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

Résultat : les buffers de sortie ne portent plus `0x4000`, restent non sécurisés, et l'encodeur les accepte.

### Prérequis et compatibilité

- **Root :** Magisk (officiel / Alpha), KernelSU, ReZukisu. Le montage est piloté par les scripts (`skip_mount`), donc les trois se comportent de la même manière.
- **Appareil / système :** conçu pour **tous les appareils HyperOS (澎湃)** — aucune liste blanche de modèles.
- Au moment de l'installation, le module **lit la bibliothèque `libsurfaceflinger.so` de l'appareil** et y localise la cible sur place (fenêtre de 16 octets → `csel+ret` de 8 octets → `csel` de 4 octets, trois niveaux, et le résultat doit être **unique**), puis construit la charge utile :
  - trouvé → charge utile générée et vérifiée, installation réussie, actif après redémarrage ;
  - **0 occurrence / plusieurs occurrences / fichier d'origine illisible → l'installation est annulée** et le module n'est jamais laissé sur le téléphone : celui-ci démarre exactement comme en usine.
- Côté système uniquement — **le récepteur n'est pas modifié, aucune application de projection tierce**.
- Le module enregistre une **empreinte d'identité** (modèle + `ro.build.fingerprint`). Après une OTA l'identité ne correspond plus : le module **se désactive tout seul** et écrit une ligne de log — il ne poussera jamais une charge utile construite pour l'ancien système sur le nouveau.

### Installation

Recommandé : gestionnaire → Modules → Installer depuis un fichier local → `Mirafix-v1.1.zip` → redémarrage.

Ou en ligne de commande :

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.1.zip
reboot
```

Idem sous Magisk / Alpha : app Magisk → Modules → Installer depuis un fichier local → redémarrage.

### Fonctionnement et sécurités

L'archive ne contient **aucun binaire précompilé** — la charge utile est produite sur l'appareil à l'installation. Le dossier du module contient un fichier `skip_mount`, donc le montage automatique est désactivé et les scripts pilotent tout.

**Barrière de démarrage (`post-fs-data.sh` ; le moindre échec abandonne l'ensemble et ne bloque jamais le boot) :**

1. Le démarrage précédent n'a pas abouti (`.boot_state` encore `pending`) → **aucun montage cette fois**, démarrage sur la bibliothèque d'origine ; deux fois de suite → écrit `disable` et s'éteint tout seul.
2. Identité : `ro.build.fingerprint` / `ro.product.model` différents de `build.info` → saut + désactivation.
3. Charge utile : md5 différent de l'enregistrement / mode différent de `0644` (auto-réparé une fois d'abord) / type SELinux ni `system_lib_file` ni `system_file` / les 4 octets corrigés sont faux → tout est sauté.
4. Tout est conforme → écrit `pending`, monte avec `nsenter -t 1 -m mount --bind`, puis **relit les 4 octets depuis la vue d'init** pour confirmer avant de laisser `surfaceflinger` démarrer.

**`service.sh` (late_start) :** confirme par **inode**, pas par chemin (après un lazy unmount le noyau rend le chemin en `/` dans maps), que SF a bien mappé la charge utile ; sinon il redémarre SF au plus deux fois, en revérifiant `0644` + type SELinux avant chaque redémarrage, et `umount -l` vers l'original immédiatement si SF ne revient pas, en laissant l'état `pending` pour que le prochain boot saute par précaution. Le compteur d'essais est remis à zéro une fois SF stable.

> ⚠️ La charge utile doit être `0644` avec le type SELinux `u:object_r:system_lib_file:s0` (identique au fichier d'origine). Avec `0600` ou `app_data_file`, `surfaceflinger` (uid 1000) ne peut pas `dlopen`, meurt 4 fois en une minute et le watchdog **redémarre le téléphone**. Les deux sont vérifiés à l'installation puis à chaque boot ; en cas d'échec, rien n'est monté.

### Note DRM

Le correctif ne touche que le **chemin de sortie de l'affichage virtuel (projection)** : la lecture DRM locale n'est pas affectée, et Mirafix **ne contourne aucun DRM**. Projeter un contenu protégé par DRM peut donner une image noire — c'est le comportement normal du DRM, pas un défaut du module.

### Dépannage / signalement

Le module embarque un bouton de diagnostic — **sans terminal** :

1. Gestionnaire → Modules → Mirafix → **Action**
2. Copiez toute la sortie et envoyez-la.

Ou partagez simplement `/data/adb/mirafix.log` (il ne contient que modèle / version système / md5 / offset — **aucun numéro de série, IMEI, MAC, compte ou autre donnée personnelle**).

Signification des lignes de log clés :

| Ligne de log | Signification |
|---|---|
| `已绑定载荷 offset=...` | Correctif actif pour ce démarrage |
| `上次启动未走完(pending)...保护性跳过` | Le boot précédent a échoué → repli sur l'original par sécurité |
| `连续 2 次启动异常，已自动禁用模块` | Le module s'est désactivé : réactivez et réinstallez |
| `系统指纹已变化（OTA？）...需重新安装` | Système mis à jour : réinstallez |
| `signature not found / matched N places` (à l'installation) | Ce build n'est pas pris en charge ; installation annulée |

### Récupération (si le téléphone ne démarre plus)

Entrez en **mode de sécurité** pour qu'aucun module ne se charge :

1. Éteignez, rallumez et **maintenez volume bas pendant l'animation de démarrage** (mode de sécurité Android ; un badge « Safe mode » apparaît).
2. Magisk désactive tous les modules en mode de sécurité ; KernelSU / ReZukisu détecte `ro.sys.safemode`, ignore tous les scripts de modules et les désactive.
3. Supprimez ou désactivez Mirafix dans le gestionnaire, puis redémarrez normalement.

Avec v1.1 vous ne devriez pas en avoir besoin : `skip_mount` et les scripts de barrière font que **la moindre anomalie** se traduit par rien de monté et un démarrage sur la bibliothèque d'origine.

### Désinstallation / retour arrière

Désactivation temporaire :

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

Désinstallation complète : supprimer le module dans le gestionnaire (ou `/data/adb/modules/mirafix`) puis redémarrer. La partition système n'est jamais modifiée — un redémarrage tout remet en état d'usine.

### Crédits & avertissement

- Rétro-ingénierie et vérification réalisées sur l'appareil ; le correctif fait 4 octets.
- À but pédagogique uniquement ; sauvegardez avant de flasher.
- Auteur : **Petittux** · GitHub : **Petittux1**

---

**许可 / License / Licence :** MIT — see [LICENSE](LICENSE)
