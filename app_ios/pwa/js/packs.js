/* 自动生成，请勿手改。
 * 数据源：knowledge/packs/*.pack.json
 * 生成命令：python tools/build_packs_js.py
 * 标准包数量：2
 */
window.WF = window.WF || {};
WF.PACKS = {
  "index": {
    "schema_version": "1.0",
    "active": {
      "fatigue": "en1993-1-9",
      "acceptance": "iso5817"
    },
    "packs": [
      {
        "pack_id": "en1993-1-9",
        "kind": "fatigue",
        "code": "EN 1993-1-9:2005",
        "title": "钢结构设计 第1-9部分：疲劳",
        "region": "EU",
        "version": "2005",
        "verified": true,
        "file": "en1993_1_9.pack.json"
      },
      {
        "pack_id": "iso5817",
        "kind": "acceptance",
        "code": "ISO 5817:2023",
        "title": "焊接 钢、镍及镍合金熔焊焊缝缺陷的质量等级",
        "region": "INT",
        "version": "2023",
        "verified": false,
        "file": "iso5817.pack.json"
      }
    ]
  },
  "packs": {
    "en1993-1-9": {
      "schema_version": "1.0",
      "pack_id": "en1993-1-9",
      "kind": "fatigue",
      "code": "EN 1993-1-9:2005",
      "title": "钢结构设计 第1-9部分：疲劳",
      "region": "EU",
      "version": "2005",
      "language": "zh-CN",
      "verified": true,
      "verification_note": "FAT 值取自工作区 EN1993-1-9_ocr.txt（表 8.1/8.2），已用 tools/extract_fat.py 校核；标注 verified=false 的条目须以原文复核。",
      "defaults": {
        "ref_N": 2000000,
        "gamma_mf_default": 1.0,
        "sn_m": 3
      },
      "sn_curve": {
        "normal_stress": {
          "m1": 3,
          "knee_N": 5000000,
          "ref_N": 2000000,
          "cafl_factor": 0.737,
          "cutoff_factor": 0.549,
          "note": "法向应力：N≤5×10^6 时斜率 m=3；等幅疲劳极限 Δσ_D=0.737·Δσc；截止极限 Δσ_L=0.549·Δσc（10^8 次）。见 OCR 第616/630行。"
        },
        "shear_stress": {
          "m": 5,
          "ref_N": 2000000,
          "cutoff_factor": 0.457,
          "note": "剪应力：斜率 m=5；截止极限 Δτ_L=0.457·Δτc。见 OCR 第614/622行。"
        }
      },
      "detail_categories": [
        {
          "id": "P1",
          "fat": 160,
          "name": "轧制/模压产品（元件1-3）",
          "verified": true,
          "note": "最高疲劳等级，需磨削消去锐边。"
        },
        {
          "id": "P4",
          "fat": 125,
          "name": "机器气割并修整的板材（元件4,5）",
          "verified": true,
          "note": "切割面机加工/磨削消去粗糙点。"
        },
        {
          "id": "P6",
          "fat": 100,
          "name": "轧制/压延产品（元件6,7）",
          "verified": true,
          "note": ""
        },
        {
          "id": "B8",
          "fat": 112,
          "name": "预载高强度螺栓双面对称接头-毛截面（元件8）",
          "verified": true,
          "note": ""
        },
        {
          "id": "B10",
          "fat": 90,
          "name": "预载注脂螺栓单面接头-毛截面（元件10）",
          "verified": true,
          "note": ""
        },
        {
          "id": "B12",
          "fat": 80,
          "name": "装配螺栓单面接头-净截面（元件12）",
          "verified": true,
          "note": ""
        },
        {
          "id": "B13",
          "fat": 50,
          "name": "非预载螺栓单/双面对称接头-净截面（元件13）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS1",
          "fat": 125,
          "name": "双面自动对接/角焊缝，连续纵焊缝（元件1,2）",
          "verified": true,
          "note": "盖板端部须按表8.5 元件6/7 检查。"
        },
        {
          "id": "WS3",
          "fat": 112,
          "name": "双面自动角焊/对焊含起止点（元件3,4）",
          "verified": true,
          "note": "有起止点则降级：元件4 用 100 类。"
        },
        {
          "id": "WS5",
          "fat": 100,
          "name": "手工角焊/对焊（元件5,6）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS8",
          "fat": 80,
          "name": "间断纵向角焊缝 g/h≤25（元件8）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS9",
          "fat": 71,
          "name": "处理孔纵向对接焊缝（高度≤60mm，元件9）",
          "verified": true,
          "note": "基于翼缘法向应力 Δσc=71。"
        },
        {
          "id": "WS10g",
          "fat": 125,
          "name": "纵向对接焊缝两面打磨与加载方向齐平+100%探伤（元件10）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS10n",
          "fat": 112,
          "name": "纵向对接焊缝无磨削无起止点（元件10）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS10s",
          "fat": 100,
          "name": "纵向对接焊缝有起止点（元件10）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS11a",
          "fat": 140,
          "name": "空心型材无起止点自动纵缝焊 t≤12.5mm（元件11）",
          "verified": true,
          "note": ""
        },
        {
          "id": "WS11b",
          "fat": 125,
          "name": "空心型材无起止点自动纵缝焊 t≥12.5mm（元件11）",
          "verified": true,
          "note": ""
        },
        {
          "id": "W_FILLET_TRANS_NLC",
          "fat": 80,
          "name": "横向非承载角焊缝（附件，焊趾受拉）",
          "verified": false,
          "note": "最常用的横向角焊缝细节；焊趾打磨可提至 100/112/125。"
        },
        {
          "id": "W_FILLET_TRANS_LC",
          "fat": 80,
          "name": "横向承载角焊缝（十字接头，传力）",
          "verified": false,
          "note": "荷载通过焊缝传递。"
        },
        {
          "id": "W_FILLET_LONG",
          "fat": 71,
          "name": "纵向角焊缝（平行受力方向）",
          "verified": false,
          "note": "平行于应力方向的非承载角焊缝。"
        },
        {
          "id": "W_BUTT_ASWELD",
          "fat": 100,
          "name": "横向对接焊缝（焊态，外形良好）",
          "verified": false,
          "note": "全熔透；打磨齐平可提至 125。"
        },
        {
          "id": "W_BUTT_GROUND",
          "fat": 125,
          "name": "横向对接焊缝（打磨与母材齐平）",
          "verified": false,
          "note": "焊态 100，打磨齐平 125。"
        },
        {
          "id": "W_COVER_END",
          "fat": 80,
          "name": "盖板端部（横向）",
          "verified": false,
          "note": "部分规范取 63；以原文校核。"
        },
        {
          "id": "W_STIFF_END",
          "fat": 80,
          "name": "加劲肋端部（横向受拉）",
          "verified": false,
          "note": ""
        }
      ],
      "improvement_methods": [
        {
          "method": "toe_grinding",
          "label": "焊趾打磨",
          "factor": 1.3,
          "max_fat": 125,
          "note": "磨削焊趾圆滑过渡；可提 FAT。"
        },
        {
          "method": "tig_dressing",
          "label": "TIG 熔修（氩弧重熔）",
          "factor": 1.3,
          "max_fat": 125,
          "note": "焊趾 TIG 重熔改善。"
        },
        {
          "method": "hammer_peening",
          "label": "锤击强化",
          "factor": 1.5,
          "max_fat": 125,
          "note": "焊趾锤击/针束锤击引入压应力。"
        },
        {
          "method": "burr_grinding",
          "label": "旋转钢丝刷打磨",
          "factor": 1.3,
          "max_fat": 100,
          "note": "仅适度改善。"
        }
      ]
    },
    "iso5817": {
      "schema_version": "1.0",
      "pack_id": "iso5817",
      "kind": "acceptance",
      "code": "ISO 5817:2023",
      "title": "焊接 钢、镍及镍合金熔焊焊缝缺陷的质量等级",
      "region": "INT",
      "version": "2023",
      "language": "zh-CN",
      "verified": false,
      "verification_note": "⚠ 数值为示例，须以 ISO 5817:2023 PDF 原文逐条校核后方可用于工程判定。",
      "levels": {
        "B": "最高要求（最高质量等级）",
        "C": "中等要求（常规）",
        "D": "较低要求"
      },
      "imperfections": [
        {
          "type": "undercut",
          "label": "咬边",
          "fatigue_relevant": true,
          "note": "位于焊趾的咬边会显著降低疲劳强度，常要求打磨或按 EN1993-1-9 降/提级处理。",
          "limits": {
            "B": {
              "value": 0.05,
              "ref": "t",
              "max_abs": 0.5,
              "formula": "≤0.05t 且最大 0.5（示例）"
            },
            "C": {
              "value": 0.1,
              "ref": "t",
              "max_abs": 1.0,
              "formula": "≤0.1t 且最大 1.0（示例）"
            },
            "D": {
              "value": 0.15,
              "ref": "t",
              "max_abs": 1.5,
              "formula": "≤0.15t 且最大 1.5（示例）"
            }
          }
        },
        {
          "type": "porosity",
          "label": "气孔",
          "fatigue_relevant": false,
          "note": "分散气孔对疲劳影响相对较小，主要按最大孔径与密集度验收。",
          "limits": {
            "B": {
              "max_pore": 0.5,
              "formula": "单孔 ≤0.5 且密度受限（示例）"
            },
            "C": {
              "max_pore": 1.0,
              "formula": "单孔 ≤1.0（示例）"
            },
            "D": {
              "max_pore": 1.5,
              "formula": "单孔 ≤1.5（示例）"
            }
          }
        },
        {
          "type": "excess_weld_metal",
          "label": "余高过大（凸度）",
          "fatigue_relevant": true,
          "note": "过大凸度造成应力集中；对接焊缝余高需平滑过渡。",
          "limits": {
            "B": {
              "formula": "余高受限且平缓过渡（示例，见原文）"
            },
            "C": {
              "formula": "（示例，见原文）"
            },
            "D": {
              "formula": "（示例，见原文）"
            }
          }
        },
        {
          "type": "overlap",
          "label": "焊瘤/满溢",
          "fatigue_relevant": true,
          "note": "焊瘤造成尖锐缺口，疲劳不利。",
          "limits": {
            "B": {
              "formula": "不允许（示例）"
            },
            "C": {
              "formula": "不允许/极轻（示例）"
            },
            "D": {
              "formula": "轻微允许（示例）"
            }
          }
        },
        {
          "type": "linear_misalignment",
          "label": "错边",
          "fatigue_relevant": true,
          "note": "对接错边引起偏心与应力集中。",
          "limits": {
            "B": {
              "value": 0.1,
              "ref": "t",
              "max_abs": 1.0,
              "formula": "≤0.1t（示例）"
            },
            "C": {
              "value": 0.15,
              "ref": "t",
              "max_abs": 2.0,
              "formula": "≤0.15t（示例）"
            },
            "D": {
              "value": 0.2,
              "ref": "t",
              "max_abs": 3.0,
              "formula": "≤0.2t（示例）"
            }
          }
        }
      ]
    }
  }
};
