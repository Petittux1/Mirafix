# Mirafix v1.0 — 解决投屏 / Fix stock casting / Correction du miroir d'écran

---

## 中文

修复小米 / HyperOS **原生投屏**连接**非小米显示器**时的 **1008 错误**。

**症状**

```
secure buffer mapping to non-secure region 8 not allowed
failed to attach. INPUT: NON_SECURE_PIXEL: idx 0 size 3219456
msm_vidc_qbuf: failed with -22
setCurWfdErrorCode=1008
```

恢复出厂设置、换机、换显示器都没用——问题在 `surfaceflinger` 的代码里。

**根因**

`QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage()` 会给输出 buffer 加 `GRALLOC_USAGE_PROTECTED(0x4000)`，导致 buffer 被分配在 secure heap，而编码器输入端只接受 non-secure，于是 `qbuf -22` → `1008`。

**补丁**（全库唯一一处，4 字节）

| 文件 | 偏移 | 修改前 | 修改后 |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

**安装**

KernelSU 管理器 → 模块 → 本地安装 `Mirafix-v1.0.zip` → 重启

或命令行：

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.0.zip
reboot
```

**回滚**

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

---

## English

Fixes the **error 1008** you get when casting with the **stock** system app from Xiaomi / HyperOS to a **non-Xiaomi** wireless display.

**Symptom**

```
secure buffer mapping to non-secure region 8 not allowed
failed to attach. INPUT: NON_SECURE_PIXEL: idx 0 size 3219456
msm_vidc_qbuf: failed with -22
setCurWfdErrorCode=1008
```

Factory reset, another phone, another display — none of it helps, because the bug lives in the `surfaceflinger` code.

**Root cause**

`QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage()` ORs `GRALLOC_USAGE_PROTECTED (0x4000)` into the output buffer usage, so the buffer lands on the **secure heap**, while the encoder input side only accepts non-secure buffers → `qbuf -22` → `1008`.

**The patch** (the only such site in the whole library, 4 bytes)

| File | Offset | Before | After |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

**Install**

KernelSU manager → Modules → Install from local → `Mirafix-v1.0.zip` → reboot

or:

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.0.zip
reboot
```

**Rollback**

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

---

## Français

Corrige l'**erreur 1008** du miroir d'écran **d'origine** de Xiaomi / HyperOS vers un écran **non Xiaomi**.

**Symptôme**

```
secure buffer mapping to non-secure region 8 not allowed
failed to attach. INPUT: NON_SECURE_PIXEL: idx 0 size 3219456
msm_vidc_qbuf: failed with -22
setCurWfdErrorCode=1008
```

Réinitialisation d'usine, autre téléphone, autre écran : rien n'aide, le bug est dans le code de `surfaceflinger`.

**Cause**

`QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage()` ajoute `GRALLOC_USAGE_PROTECTED (0x4000)` à l'usage du buffer de sortie ; celui-ci est donc alloué sur le **heap secure**, alors que l'entrée de l'encodeur n'accepte que du non-sécurisé → `qbuf -22` → `1008`.

**Le correctif** (seul site concerné dans toute la bibliothèque, 4 octets)

| Fichier | Offset | Avant | Après |
|---|---|---|---|
| `libsurfaceflinger.so` | `0x5b9ba8` | `csel x0,x11,x8,ne` (`6011889a`) | `mov x0,x8` (`e00308aa`) |

**Installation**

Gestionnaire KernelSU → Modules → Installer depuis un fichier local → `Mirafix-v1.0.zip` → redémarrage

ou :

```sh
/data/adb/ksud module install /sdcard/Download/Mirafix-v1.0.zip
reboot
```

**Retour arrière**

```sh
su -c touch /data/adb/modules/mirafix/disable
reboot
```

---

### 📦 Fichier / Asset

- `Mirafix-v1.0.zip` — KernelSU / ReZukisu 模块包，直接在管理器里安装即可。

### ✅ 要求 / Requirements / Prérequis

- Root: **KernelSU / ReZukisu**
- 测试机型 / Tested on / Testé sur: **Xiaomi 17 Pro / HyperOS 4**
- 系统侧改动，**不动接收端、不用第三方投屏 App** / system-side only, sink untouched, no third-party casting app / côté système uniquement, récepteur inchangé, aucune app tierce
