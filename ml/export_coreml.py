#!/usr/bin/env python3
# export_coreml.py —— 安全的 CoreML 重导出脚本（避免拿到陈旧/无编号权重，确保 INT8 生效）
#
# 适用场景：训练已在 AI Studio 跑完（runs/detect/weld_defect_5cls-N/ 下已有 best.pt），
# 但你想换一份干净的导出、或之前误从「无编号」目录导出了陈旧权重。
#
# 用法（在 AI Studio work/ 目录下）：
#   !python ml/export_coreml.py
# 或直接 %run ml/export_coreml.py
#
# 关键修复（针对 2026-09-27 实战踩坑）：
#  1) 自动选取 epoch 数最多的 run 目录（runs/detect/weld_defect_5cls*/results.csv 行数最多者），
#     从它的 weights/best.pt 导出。绝不用无编号的 weld_defect_5cls/weights/best.pt
#     —— 那是第 1 次运行的陈旧权重，续训不会更新它（已实测踩坑）。
#  2) int8=True 必须配合 data= 校准集，否则 coremltools 静默回退 FP32（体积 ~5.9MB）。
#     本脚本显式传 data='dataset/data.yaml'，真 INT8 导出后体积应约 1.5MB。
#  3) nms=True：与 App 端 MLDefectDetector.runModel 的双输出解析（coordinates/confidence）匹配。
#  4) 导出后重命名为 WeldDefectModel.mlpackage（与 App 的 modelFileName 一致）。
#
# 验证：脚本结束会打印体积；若 >3MB 说明 INT8 未生效，需检查导出日志是否含量化步骤、data= 路径是否有效。

import os
import glob
import shutil

from ultralytics import YOLO

TRAIN_NAME = 'weld_defect_5cls'
DATA_YAML = 'dataset/data.yaml'


def epochs_of(results_csv):
    """results.csv 第 1 行为表头，其后每 epoch 一行；行数-1 = epoch 数。"""
    try:
        with open(results_csv) as f:
            return max(0, sum(1 for _ in f) - 1)
    except OSError:
        return -1


def pick_best_run():
    runs = sorted(glob.glob(f'runs/detect/{TRAIN_NAME}*/results.csv'))
    if not runs:
        raise SystemExit(f'[错误] 未找到任何 {TRAIN_NAME}* 训练目录，请确认训练已完成且 cwd 在 work/。')
    best = max(runs, key=epochs_of)
    ckpt = os.path.join(os.path.dirname(best), 'weights', 'best.pt')
    print(f'[选择] run = {os.path.dirname(best)}')
    print(f'[epoch] {epochs_of(best)}')
    print(f'[权重] {ckpt}')
    if not os.path.exists(ckpt):
        raise SystemExit(f'[错误] 未找到 {ckpt}，请确认该 run 已保存 best.pt（未被环境清空）。')
    return ckpt


def main():
    ckpt = pick_best_run()
    model = YOLO(ckpt)
    # CoreML 量化（Ultralytics 8.4.x）：
    #   - 不支持 data= 给 CoreML，且 int8=True 已废弃并会静默回退 FP32；
    #   - 唯一可用档 quantize='w8a16'（INT8 权重 + 16-bit 激活，权重-only，免校准，~1.5-3.5MB）。
    exported = model.export(format='coreml', nms=True, quantize='w8a16', imgsz=640)
    print('[导出]', exported)

    pkg_name = 'WeldDefectModel.mlpackage' if os.path.isdir(exported) else 'WeldDefectModel.mlmodel'
    if os.path.exists(pkg_name):
        if os.path.isdir(pkg_name):
            shutil.rmtree(pkg_name)
        else:
            os.remove(pkg_name)
    shutil.move(exported, pkg_name)

    # .mlpackage 是目录，os.path.getsize 只返回目录项大小（≈4KB），必须用 walk 算真实总体积
    if os.path.isdir(pkg_name):
        size_mb = sum(os.path.getsize(os.path.join(d, f))
                      for d, _, fs in os.walk(pkg_name) for f in fs) / 1e6
    else:
        size_mb = os.path.getsize(pkg_name) / 1e6
    print(f'[完成] 已导出 {pkg_name}  ({size_mb:.1f} MB)')
    if size_mb > 4.5:
        print('[警告] 体积 >4.5MB，量化很可能未生效（w8a16 应约 1.5-3.5MB，FP32 才是 ~5.9MB）。'
              '请检查导出日志是否含 palettize_weights 压缩通道。')

    # 自动打包成 zip 方便下载（AI Studio 右键下 .mlpackage 文件夹无效）
    if os.path.isdir(pkg_name):
        zip_base = os.path.join(os.getcwd(), 'WeldDefectModel')
        shutil.make_archive(zip_base, 'zip', root_dir=os.getcwd(), base_dir=pkg_name)
        print(f'[打包] 可下载：{zip_base}.zip')
    else:
        shutil.copy(pkg_name, os.path.join(os.getcwd(), 'WeldDefectModel.mlmodel'))
        print('[打包] 可下载：WeldDefectModel.mlmodel')


if __name__ == '__main__':
    main()
