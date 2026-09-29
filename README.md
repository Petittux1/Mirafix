# Mirafix — 解决投屏

[English](#english) · [中文](#中文) · [Français](#français)

修复小米 / HyperOS **原生投屏**（Miracast / WFD）连接**非小米显示器**时失败的问题。
Fixes **stock** Miracast / WFD casting from Xiaomi / HyperOS to **non-Xiaomi displays**.
Corrige le miroir d'écran **d'origine** (Miracast / WFD) de Xiaomi / HyperOS vers un **écran non Xiaomi**.

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

### 补丁

把 4 个字节换掉，让它永远走「不加保护位」的分支：

| 位置 | 原指令 | 补丁后 |
|---|---|---|
| `libsurfaceflinger.so` `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

净效果：输出 buffer 永远不带 `0x4000`，不再落 secure heap，编码器正常接收。

### 要求

- 已 root 的 **KernelSU / ReZukisu**（其它 root 方案未测试）
- 测试机型：**Xiaomi 17 Pro / HyperOS 4**，`ro.product.first_api_level` ≥ 34
- 只改系统侧，**不改投影接收端、不装任何第三方投屏 App**

### 安装

方式一（推荐）：KernelSU 管理器 → 模块 → 从本地安装 `Mirafix-v1.0.zip` → 重启。

方式二：命令行

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.0.zip
reboot
```

### 工作方式与安全兜底

模块有三层：

1. **魔法挂载**：`system_ext/lib64/libsurfaceflinger.so` 由 KernelSU 在 post-fs-data 之前挂载——这是正常生效路径，实测抢在 `surfaceflinger` 启动前完成。
2. **`post-fs-data.sh`**：读取偏移 `6003624`（`0x5b9ba8`）的 4 字节比对 `e00308aa`，不对就用 `nsenter -t 1 -m` 兜底绑定。
3. **`service.sh`**：按 **inode**（不是路径，因为 lazy unmount 后内核会把 maps 路径渲染成 `/`）确认 `surfaceflinger` 真的加载了补丁库；没加载才重启一次 SF，且重启前强制检查载荷是 `0644`，SF 起不来立刻 `umount -l` 回滚原版。

> ⚠️ 载荷权限必须是 `0644` + SELinux 类型 `system_lib_file`（与原文件一致）。若是 `0600` 或 `app_data_file`，`surfaceflinger`（uid 1000）`dlopen` 失败，连崩 4 次会触发看门狗**整机重启**。本模块已固化这两个属性。

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
- 作者：**Petittux**

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

### The patch

Four bytes, forcing the "never protected" branch:

| File | Offset | Before | After |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

Net effect: output buffers never carry `0x4000`, they stay non-secure, and the encoder accepts them.

### Requirements

- Rooted **KernelSU / ReZukisu** (other root solutions untested)
- Tested on **Xiaomi 17 Pro / HyperOS 4**, `ro.product.first_api_level` ≥ 34
- System side only — **the sink is untouched, no third-party casting app is used**

### Install

Recommended: KernelSU manager → Modules → Install from local → `Mirafix-v1.0.zip` → reboot.

Or from a shell:

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.0.zip
reboot
```

### How it works, and the safety rails

Three layers:

1. **Magic mount** — `system_ext/lib64/libsurfaceflinger.so` is mounted by KernelSU before post-fs-data; in practice this wins the race against `surfaceflinger` startup, so no SF restart is needed.
2. **`post-fs-data.sh`** — reads 4 bytes at offset `6003624` (`0x5b9ba8`) and compares with `e00308aa`; on mismatch it falls back to an explicit `nsenter -t 1 -m` bind mount.
3. **`service.sh`** — confirms `surfaceflinger` really mapped the patched library by **inode** (not by path: after a lazy unmount the kernel renders the maps path as `/`), restarts SF once only if needed, refuses to restart unless the payload is `0644`, and immediately `umount -l`s back to stock if SF fails to come up.

> ⚠️ The payload must be `0644` with SELinux type `system_lib_file` (identical to the original file). With `0600` or `app_data_file`, `surfaceflinger` (uid 1000) cannot `dlopen` it, dies 4 times in a minute and the watchdog **reboots the phone**. Both attributes are baked into this module.

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
- Author: **Petittux**

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

### Le correctif

Quatre octets, en forçant la branche « jamais protégé » :

| Fichier | Offset | Avant | Après |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

Résultat : les buffers de sortie ne portent plus `0x4000`, restent non sécurisés, et l'encodeur les accepte.

### Prérequis

- **KernelSU / ReZukisu** rooté (autres solutions de root non testées)
- Testé sur **Xiaomi 17 Pro / HyperOS 4**, `ro.product.first_api_level` ≥ 34
- Côté système uniquement — **le récepteur n'est pas modifié, aucune application de projection tierce**

### Installation

Recommandé : gestionnaire KernelSU → Modules → Installer depuis un fichier local → `Mirafix-v1.0.zip` → redémarrage.

Ou en ligne de commande :

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.0.zip
reboot
```

### Fonctionnement et sécurités

Trois couches :

1. **Magic mount** — `system_ext/lib64/libsurfaceflinger.so` est monté par KernelSU avant post-fs-data ; en pratique il gagne la course contre le démarrage de `surfaceflinger`, donc aucun redémarrage de SF n'est nécessaire.
2. **`post-fs-data.sh`** — lit 4 octets à l'offset `6003624` (`0x5b9ba8`) et compare à `e00308aa` ; en cas d'écart, il pose un bind mount de secours via `nsenter -t 1 -m`.
3. **`service.sh`** — vérifie que `surfaceflinger` a bien mappé la bibliothèque corrigée en se basant sur l'**inode** (pas sur le chemin : après un lazy unmount le noyau rend le chemin en `/` dans maps), ne redémarre SF qu'une seule fois si nécessaire, refuse de le faire si la charge utile n'est pas en `0644`, et `umount -l` immédiatement vers l'original si SF ne redémarre pas.

> ⚠️ La charge utile doit être `0644` avec le type SELinux `system_lib_file` (identique au fichier d'origine). Avec `0600` ou `app_data_file`, `surfaceflinger` (uid 1000) ne peut pas `dlopen` meurt 4 fois en une minute et le watchdog **redémarre le téléphone**. Ces deux attributs sont figés dans ce module.

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
- Auteur : **Petittux**

---

**许可 / License / Licence :** MIT — see [LICENSE](LICENSE)
