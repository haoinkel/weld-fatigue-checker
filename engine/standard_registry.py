# -*- coding: utf-8 -*-
"""
standard_registry.py —— 标准包（Standard Pack）注册表：对外开放的「标准扩展接口」。

设计目标
--------
后续要补充新标准（GB 50017、GB/T 3811、IIW、AWS D1.1、BS 7608、DNV-RP-C203 …），
**不需要改动任何引擎代码**：把符合 schema 的 `xxx.pack.json` 放进
`knowledge/packs/`（或用 --import 导入），注册表自动发现，切换为 active 后即刻生效。

标准包 schema（schema_version = "1.0"）
--------------------------------------
公共必需字段：
  schema_version, pack_id, kind("fatigue"|"acceptance"), code, title, version
公共可选字段：
  region, language, verified(bool), verification_note, note

kind = "fatigue"（疲劳标准，提供细节→FAT）：
  detail_categories : [{id, fat, name, verified?, note?}]
  improvement_methods: [{method, label, factor, max_fat, note?}]
  defaults          : {ref_N, gamma_mf_default, sn_m}
  sn_curve          : {...}

kind = "acceptance"（验收标准，提供缺陷限值）：
  imperfections     : [{type, label, fatigue_relevant, limits:{B|C|D:{value,ref,max_abs,max_pore}}}]
  levels            : {"B": "...", "C": "...", "D": "..."}

命令行
------
  python engine/standard_registry.py --list
  python engine/standard_registry.py --info
  python engine/standard_registry.py --validate
  python engine/standard_registry.py --import 路径/GB50017.pack.json
  python engine/standard_registry.py --set-fatigue gb50017
  python engine/standard_registry.py --set-acceptance iso5817
"""
import argparse
import glob
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KNOWLEDGE = os.path.join(ROOT, "knowledge")
PACKS_DIR = os.path.join(KNOWLEDGE, "packs")
INDEX_FILE = os.path.join(PACKS_DIR, "_index.json")

SCHEMA_VERSION = "1.0"
KINDS = ("fatigue", "acceptance")

COMMON_REQUIRED = ["schema_version", "pack_id", "kind", "code", "title", "version"]
KIND_REQUIRED = {
    "fatigue": ["detail_categories", "improvement_methods"],
    "acceptance": ["imperfections"],
}


# --------------------------------------------------------------------------
# 基础 IO
# --------------------------------------------------------------------------
def _read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _write_json(path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)


def read_index():
    if not os.path.exists(INDEX_FILE):
        return {"schema_version": SCHEMA_VERSION,
                "active": {"fatigue": None, "acceptance": None}, "packs": []}
    try:
        idx = _read_json(INDEX_FILE)
    except Exception:
        idx = {}
    idx.setdefault("schema_version", SCHEMA_VERSION)
    idx.setdefault("active", {})
    idx.setdefault("packs", [])
    return idx


def write_index(idx):
    os.makedirs(PACKS_DIR, exist_ok=True)
    _write_json(INDEX_FILE, idx)


# --------------------------------------------------------------------------
# 校验
# --------------------------------------------------------------------------
def validate(pack):
    """校验标准包。返回 (ok: bool, errors: [str], warnings: [str])。"""
    errors, warnings = [], []
    if not isinstance(pack, dict):
        return False, ["标准包必须是 JSON 对象"], warnings

    for key in COMMON_REQUIRED:
        if key not in pack:
            errors.append(f"缺少必需字段: {key}")
    kind = pack.get("kind")
    if kind and kind not in KINDS:
        errors.append(f"kind 必须为 {KINDS} 之一，当前为 {kind!r}")
        kind = None
    if kind:
        for key in KIND_REQUIRED.get(kind, []):
            if key not in pack:
                errors.append(f"{kind} 类型标准包缺少字段: {key}")

    sv = pack.get("schema_version")
    if sv and str(sv) != SCHEMA_VERSION:
        warnings.append(f"schema_version={sv}，当前程序支持 {SCHEMA_VERSION}，可能存在兼容差异")

    if kind == "fatigue":
        for i, d in enumerate(pack.get("detail_categories", [])):
            if "id" not in d or "fat" not in d:
                errors.append(f"detail_categories[{i}] 缺少 id 或 fat")
        for i, m in enumerate(pack.get("improvement_methods", [])):
            if "method" not in m or "factor" not in m:
                errors.append(f"improvement_methods[{i}] 缺少 method 或 factor")
    if kind == "acceptance":
        for i, it in enumerate(pack.get("imperfections", [])):
            if "type" not in it or "limits" not in it:
                errors.append(f"imperfections[{i}] 缺少 type 或 limits")

    if pack.get("verified") is False:
        warnings.append("该标准包标记 verified=false，数值须经原文校核后方可用于工程判定")
    return (len(errors) == 0), errors, warnings


# --------------------------------------------------------------------------
# 发现 / 加载
# --------------------------------------------------------------------------
def scan_files():
    """扫描 packs 目录下所有 *.pack.json，返回 {pack_id: {"file":..., "meta":{...}}}。"""
    found = {}
    if not os.path.isdir(PACKS_DIR):
        return found
    for path in sorted(glob.glob(os.path.join(PACKS_DIR, "*.pack.json"))):
        try:
            pack = _read_json(path)
        except Exception:
            continue
        pid = pack.get("pack_id")
        if not pid:
            continue
        found[pid] = {
            "file": os.path.basename(path),
            "meta": {"pack_id": pid, "kind": pack.get("kind"), "code": pack.get("code"),
                     "title": pack.get("title"), "region": pack.get("region"),
                     "version": str(pack.get("version", "")),
                     "verified": bool(pack.get("verified", False))},
        }
    return found


def discover(sync_index=True):
    """发现全部标准包；并把新发现的文件并入索引（实现「丢文件即可用」）。"""
    idx = read_index()
    files = scan_files()
    known = {p.get("pack_id"): p for p in idx.get("packs", [])}
    changed = False
    for pid, info in files.items():
        if pid not in known:
            idx["packs"].append(info["meta"])
            known[pid] = info["meta"]
            changed = True
        else:
            known[pid].update(info["meta"])
            changed = True
    # 清理索引中文件已删除的条目
    idx["packs"] = [p for p in idx.get("packs", []) if p.get("pack_id") in files]
    # active 指向不存在的包时自动纠正
    for kind in KINDS:
        cur = idx.get("active", {}).get(kind)
        if cur not in files:
            cand = next((p for p in idx["packs"] if p.get("kind") == kind), None)
            idx["active"][kind] = cand["pack_id"] if cand else None
            changed = True
    if sync_index and changed:
        write_index(idx)
    return idx


def load(pack_id):
    """按 pack_id 加载完整标准包内容。"""
    files = scan_files()
    if pack_id not in files:
        raise KeyError(f"未找到标准包: {pack_id}")
    return _read_json(os.path.join(PACKS_DIR, files[pack_id]["file"]))


def list_packs():
    idx = discover()
    return idx.get("packs", [])


# --------------------------------------------------------------------------
# 切换 / 导入 / 升级 / 移除
# --------------------------------------------------------------------------
def set_active(kind, pack_id):
    """启用指定 kind 的标准包。"""
    if kind not in KINDS:
        raise ValueError(f"kind 必须为 {KINDS} 之一")
    pack = load(pack_id)
    if pack.get("kind") != kind:
        raise ValueError(f"标准包 {pack_id} 的 kind={pack.get('kind')}，与 {kind} 不匹配")
    ok, errors, _ = validate(pack)
    if not ok:
        raise ValueError("标准包校验失败: " + "; ".join(errors))
    idx = discover()
    idx["active"][kind] = pack_id
    write_index(idx)
    return pack


def active_id(kind):
    return discover().get("active", {}).get(kind)


def import_pack(src_path, overwrite=True):
    """
    导入（或升级）一个标准包文件。
    - 相同 pack_id 视为升级：比较 version，覆盖并给出 old->new 提示。
    - 返回 (meta, message)
    """
    pack = _read_json(src_path)
    ok, errors, warnings = validate(pack)
    if not ok:
        raise ValueError("标准包校验失败:\n  - " + "\n  - ".join(errors))

    pid = pack["pack_id"]
    os.makedirs(PACKS_DIR, exist_ok=True)
    idx = discover()

    old = next((p for p in idx["packs"] if p.get("pack_id") == pid), None)
    msg = ""
    if old and not overwrite:
        raise ValueError(f"标准包 {pid} 已存在（version={old.get('version')}），如需升级请允许覆盖")
    if old:
        msg = f"升级标准包 {pid}: version {old.get('version')} -> {pack.get('version')}"
    else:
        msg = f"新增标准包 {pid} (version={pack.get('version')})"

    safe = "".join(c if (c.isalnum() or c in "-_") else "_" for c in pid)
    dst = os.path.join(PACKS_DIR, f"{safe}.pack.json")
    shutil.copyfile(src_path, dst)

    idx = discover()   # 重新扫描以纳入新文件
    # 若该 kind 尚无 active，自动启用首个
    if not idx.get("active", {}).get(pack["kind"]):
        idx["active"][pack["kind"]] = pid
    write_index(idx)

    meta = next(p for p in idx["packs"] if p.get("pack_id") == pid)
    return meta, msg + ("；已自动启用" if idx["active"].get(pack["kind"]) == pid else "")


def remove_pack(pack_id):
    files = scan_files()
    if pack_id not in files:
        raise KeyError(f"未找到标准包: {pack_id}")
    os.remove(os.path.join(PACKS_DIR, files[pack_id]["file"]))
    idx = discover()
    return f"已移除标准包 {pack_id}"


# --------------------------------------------------------------------------
# 供引擎消费的归一化视图
# --------------------------------------------------------------------------
def _legacy_fatigue():
    with open(os.path.join(KNOWLEDGE, "en1993_1_9.json"), "r", encoding="utf-8") as fh:
        src = json.load(fh)
    return {"pack_id": "en1993-1-9(legacy)", "code": src.get("standard"),
            "title": "EN 1993-1-9 (legacy)", "version": "2005",
            "ref_N": 2_000_000, "gamma_mf_default": src.get("gamma_mf_default", 1.0),
            "detail_categories": src["detail_categories"],
            "improvement_methods": src["improvement_methods"],
            "verified": True, "source": "legacy"}


def _legacy_acceptance():
    with open(os.path.join(KNOWLEDGE, "iso5817.json"), "r", encoding="utf-8") as fh:
        src = json.load(fh)
    return {"pack_id": "iso5817(legacy)", "code": src.get("standard"),
            "title": "ISO 5817 (legacy)", "version": "2023",
            "levels": src.get("levels", {}), "imperfections": src["imperfections"],
            "verified": False, "source": "legacy"}


def fatigue_view():
    """当前启用的疲劳标准视图（优先标准包，失败回退旧 JSON）。"""
    try:
        pid = active_id("fatigue")
        if pid:
            p = load(pid)
            d = p.get("defaults", {})
            return {"pack_id": p["pack_id"], "code": p.get("code"), "title": p.get("title"),
                    "version": str(p.get("version", "")),
                    "ref_N": d.get("ref_N", 2_000_000),
                    "gamma_mf_default": d.get("gamma_mf_default", 1.0),
                    "sn_m": d.get("sn_m", 3),
                    "detail_categories": p.get("detail_categories", []),
                    "improvement_methods": p.get("improvement_methods", []),
                    "verified": bool(p.get("verified", False)),
                    "source": "pack"}
    except Exception:
        pass
    return _legacy_fatigue()


def acceptance_view():
    """当前启用的验收标准视图。"""
    try:
        pid = active_id("acceptance")
        if pid:
            p = load(pid)
            return {"pack_id": p["pack_id"], "code": p.get("code"), "title": p.get("title"),
                    "version": str(p.get("version", "")),
                    "levels": p.get("levels", {}), "imperfections": p.get("imperfections", []),
                    "verified": bool(p.get("verified", False)), "source": "pack"}
    except Exception:
        pass
    return _legacy_acceptance()


def info():
    idx = discover()
    lines = ["已注册标准包："]
    for p in idx.get("packs", []):
        mark = "✓" if p.get("verified") else "!"
        lines.append(f"  [{mark}] {p.get('kind'):10s} {p.get('pack_id'):16s} "
                     f"{p.get('code')}  (region={p.get('region')}, v{p.get('version')})")
    lines.append("当前启用：")
    for kind in KINDS:
        lines.append(f"  {kind:10s} -> {idx.get('active', {}).get(kind)}")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="标准包注册表（开放的标准扩展接口）")
    ap.add_argument("--list", action="store_true", help="列出全部标准包")
    ap.add_argument("--info", action="store_true", help="显示注册与启用状态")
    ap.add_argument("--validate", action="store_true", help="校验全部标准包")
    ap.add_argument("--import", dest="imp", metavar="FILE", help="导入/升级标准包 JSON")
    ap.add_argument("--set-fatigue", metavar="PACK_ID", help="启用指定疲劳标准")
    ap.add_argument("--set-acceptance", metavar="PACK_ID", help="启用指定验收标准")
    ap.add_argument("--remove", metavar="PACK_ID", help="移除标准包")
    args = ap.parse_args(argv)

    if args.list or args.info:
        print(info())
    if args.validate:
        idx = discover()
        for p in idx.get("packs", []):
            try:
                pack = load(p["pack_id"])
                ok, errors, warnings = validate(pack)
                print(f"[{'OK ' if ok else 'ERR'}] {p['pack_id']}: {p.get('code')}")
                for e in errors:
                    print("      错误:", e)
                for w in warnings:
                    print("      提示:", w)
            except Exception as exc:
                print(f"[ERR] {p['pack_id']}: {exc}")
    if args.imp:
        meta, msg = import_pack(args.imp)
        print(msg)
        print(json.dumps(meta, ensure_ascii=False, indent=2))
    if args.set_fatigue:
        p = set_active("fatigue", args.set_fatigue)
        print(f"已启用疲劳标准: {p.get('code')}")
    if args.set_acceptance:
        p = set_active("acceptance", args.set_acceptance)
        print(f"已启用验收标准: {p.get('code')}")
    if args.remove:
        print(remove_pack(args.remove))
    if not any([args.list, args.info, args.validate, args.imp,
                args.set_fatigue, args.set_acceptance, args.remove]):
        print(info())
    return 0


if __name__ == "__main__":
    sys.exit(main())
