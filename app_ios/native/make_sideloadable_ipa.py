#!/usr/bin/env python3
"""
make_sideloadable_ipa.py
=======================
将任意 IPA 后处理为「可直接侧载」的版本（已在 iPadOS 26.6.2 实测通过）。

解决的问题
----------
侧载安装时报：`APIInternalError / IXErrorDomain Code=13 / Failed to get bundle ID / Missing bundle ID`。
根因：iOS 的 `.app` 包内不允许存在 `Resources/` 子目录（资源必须平铺在 bundle 根目录）。
若安装包是手工组装、把资源放在 `.app/Resources/` 下，设备端 CFBundle 解析 bundle 会失败，
在读不到 bundle id 的阶段（签名校验之前）即中止，导致 AltServer / Sideloadly / pymobiledevice3
三条通道全部失败在同一步。

本脚本做的事（与通过的 v3 完全一致）
-----------------------------------
1. 把每个 `.app/Resources/` 下的文件平铺到 `.app/` 根目录（消除 Resources/ 子目录）。
2. 规范化 Info.plist：补齐缺失的标准键（CFBundleInfoDictionaryVersion、
   CFBundleDevelopmentRegion），并以二进制 plist 重新写出。
3. 设置规范 unix 文件属性（目录 0755、可执行 0755、其它数据文件 0644），
   与可正常安装的参考包（SideStore）一致。

用法
----
    python3 make_sideloadable_ipa.py input.ipa [-o output.ipa]

若省略 -o，则在 input 同目录生成 `input.sideload.ipa`。
"""
import argparse
import os
import plistlib
import sys
import zipfile

# 规范 unix 属性：高位为 mode（含文件类型位），低 16 位为 DOS 属性
def attrs_for(filename: str, is_dir: bool) -> int:
    if is_dir:
        mode = 0o40755
        dos = 0x10
    else:
        # 可执行文件（无扩展名或已知 Mach-O）给 0755，其余 0644
        base = os.path.basename(filename)
        exe_like = (os.path.splitext(base)[1] == "" or base in ("WeldFatigueChecker",))
        mode = 0o100755 if exe_like else 0o100644
        dos = 0x00
    return (mode << 16) | dos


def find_app_dirs(names):
    """返回 Payload 下所有 .app 目录前缀，如 ['Payload/WeldFatigueChecker.app/']"""
    apps = set()
    for n in names:
        if n.startswith("Payload/") and n.endswith(".app/"):
            apps.add(n)
    return sorted(apps)


def normalize_plist(raw: bytes) -> bytes:
    try:
        p = plistlib.loads(raw)
    except Exception:
        # 不是合法 plist 就不动
        return raw
    if not isinstance(p, dict):
        return raw
    p.setdefault("CFBundleInfoDictionaryVersion", "6.0")
    p.setdefault("CFBundleDevelopmentRegion", "en")
    # 保证关键键存在（缺则补默认值，便于排查）
    p.setdefault("CFBundlePackageType", "APPL")
    p.setdefault("CFBundleSupportedPlatforms", ["iPhoneOS"])
    p = dict(sorted(p.items()))  # Xcode 习惯按字母序，便于 diff
    return plistlib.dumps(p, fmt=plistlib.FMT_BINARY)


def process(src: str, dst: str):
    zin = zipfile.ZipFile(src)
    all_names = zin.namelist()
    app_dirs = find_app_dirs(all_names)

    if not app_dirs:
        sys.exit("ERROR: 在 IPA 中未找到 Payload/*.app/ ，这不是合法的 iOS 应用包。")

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            n = info.filename
            if n.endswith("/"):
                continue  # 目录稍后规范化重建
            data = zin.read(n)

            # 平铺 Resources/：把 ".app/Resources/" 前缀去掉，文件落到 .app/ 根
            new = n
            for app in app_dirs:
                prefix = app + "Resources/"
                if new.startswith(prefix):
                    new = app + new[len(prefix):]
                    break

            if new.endswith(".app/"):  # 防御：避免空目录条目
                continue

            if new.endswith("Info.plist"):
                data = normalize_plist(data)

            zi = zipfile.ZipInfo(new, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = attrs_for(new, is_dir=False)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zout.writestr(zi, data)

        # 重建规范目录条目
        for app in app_dirs:
            # 收集该 app 下的所有目录（含被平铺后产生的新目录，这里只补 Payload 链）
            pass
        for d in ["Payload/"] + app_dirs:
            zi = zipfile.ZipInfo(d, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = attrs_for(d, is_dir=True)
            zout.writestr(zi, b"")

    # 校验
    z = zipfile.ZipFile(dst)
    bad = [n for n in z.namelist() if "/Resources/" in n and n.endswith(".app/Resources/") is False and ".app/Resources/" in n]
    # 上面条件恒成立，改为直接检测是否还存在 .app/Resources/ 条目
    has_resources = any(".app/Resources/" in n for n in z.namelist())
    print(f"written: {dst}")
    print(f"entries: {len(z.namelist())}")
    print(f"contains .app/Resources/ : {has_resources}  (应为 False)")
    p = plistlib.loads(z.read([n for n in z.namelist() if n.endswith('Info.plist') and not '/PlugIns/' in n][0]))
    print(f"CFBundleIdentifier: {p.get('CFBundleIdentifier')}")
    if has_resources:
        sys.exit("WARN: 仍存在 Resources/ 子目录，请检查输入包结构。")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args()
    if not os.path.exists(args.input):
        sys.exit(f"ERROR: 找不到输入文件 {args.input}")
    out = args.output or (os.path.splitext(args.input)[0] + ".sideload.ipa")
    process(args.input, out)
    print("OK")


if __name__ == "__main__":
    main()
