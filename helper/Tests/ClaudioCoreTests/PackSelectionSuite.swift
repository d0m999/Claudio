import ClaudioCore
import Foundation

// MARK: - packSelection: D23 定稿②「读」这半条正交轴 —— 只读 config.json 本身，三态

@MainActor
func runPackSelectionSuites() {
    suite("packSelection: config.json 不存在 → .notSelected（全新安装，不是错误）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            expect(
                packSelection(configFile: configFile) == .notSelected,
                "缺失的文件必须是 .notSelected，got \(packSelection(configFile: configFile))")
        }
    }

    suite("packSelection: selected_pack 是空串 → .notSelected（与文件不存在是同一件事）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "" }"#, to: configFile)
            expect(
                packSelection(configFile: configFile) == .notSelected,
                "空串 selected_pack 必须是 .notSelected，got \(packSelection(configFile: configFile))")
        }
    }

    suite("packSelection: selected_pack 是一个非空字符串 → .selected(packID:)，不校验它是否真的存在") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            // 刻意不建任何 packs 目录——packSelection 只读 config.json 自己，不碰磁盘上的包。
            writeFixture(#"{ "selected_pack": "ghost-pack" }"#, to: configFile)
            expect(
                packSelection(configFile: configFile) == .selected(packID: "ghost-pack"),
                "非空 selected_pack 必须是 .selected，即使它解析不出真实的包目录（那是"
                    + " checkPackIntegrity 的职责，不是这里），got \(packSelection(configFile: configFile))"
            )
        }
    }

    suite("packSelection: 顶层不是 JSON 对象 → .malformed") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("[1, 2, 3]", to: configFile)
            guard case .malformed = packSelection(configFile: configFile) else {
                expect(false, "数组顶层必须是 .malformed，got \(packSelection(configFile: configFile))")
                return
            }
        }
    }

    suite("packSelection: 缺少 selected_pack 这个必需键 → .malformed") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "master_volume": 0.5 }"#, to: configFile)
            guard case .malformed = packSelection(configFile: configFile) else {
                expect(
                    false, "缺 selected_pack 必须是 .malformed，got \(packSelection(configFile: configFile))")
                return
            }
        }
    }

    suite("packSelection: selected_pack 不是字符串（是数字）→ .malformed，不猜不重建") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": 42 }"#, to: configFile)
            guard case .malformed = packSelection(configFile: configFile) else {
                expect(
                    false,
                    "selected_pack 是数字必须是 .malformed，got \(packSelection(configFile: configFile))")
                return
            }
        }
    }

    suite("packSelection: config.json 是一个目录 → .malformed，绝不挂起、绝不崩溃") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            try? FileManager.default.createDirectory(
                at: configFile, withIntermediateDirectories: true)
            guard case .malformed = packSelection(configFile: configFile) else {
                expect(
                    false,
                    "目录形状的 config.json 必须是 .malformed，got \(packSelection(configFile: configFile))"
                )
                return
            }
        }
    }

    suite(
        "packSelection 与 checkPackIntegrity 对同一份读不出来的 config.json 给出逐字相同的 reason"
            + "（两条读路径描述的是同一件事，不该各自发明说法）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: configFile, withIntermediateDirectories: true)

            guard case .malformed(let selectionReason) = packSelection(configFile: configFile) else {
                expect(false, "setup: packSelection 必须判它 .malformed")
                return
            }
            guard
                case .configUnreadable(let integrityReason) = checkPackIntegrity(
                    configFile: configFile, userPacksDirectory: userPacks,
                    bundledPacksDirectory: nil)
            else {
                expect(false, "setup: checkPackIntegrity 必须判它 .configUnreadable")
                return
            }
            expect(
                selectionReason == integrityReason,
                "packSelection 与 checkPackIntegrity 必须给出同一句话，got"
                    + " packSelection=\(selectionReason) / checkPackIntegrity=\(integrityReason)")
        }
    }

    // MARK: - 合成矩阵：packSelection（读）× probeConfigRewritable（写）—— 两条正交轴，缺一不可
    //
    // D23 定稿②本轮最容易漏的一条：一份「读得动、写不动」的 config，只问「读」这一半会被误判成
    // 可用——面板会渲染全套活控件，而用户点下去的每一次静音 / 切包都注定失败
    // （``ConfigMutation.swift`` 的 `probeConfigRewritable` 文档已经点名了这个洞）。这里把这条
    // divergence 钉死在两个原语本身上，而不是等到面板路由层才第一次被测到。

    suite(
        "合成矩阵：一份 selected_pack 正常、但 master_volume 是字符串的 config —— packSelection"
            + " 说「选了」，probeConfigRewritable 说「写不了」，两者必须不一致（这正是要两条轴的理由）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "lofi", "master_volume": "0.35" }"#, to: configFile)

            expect(
                packSelection(configFile: configFile) == .selected(packID: "lofi"),
                "读这一半只看 selected_pack，master_volume 的类型不归它管，got"
                    + " \(packSelection(configFile: configFile))")

            guard case .malformed = probeConfigRewritable(configFile: configFile) else {
                expect(
                    false,
                    "写这一半必须判它 .malformed（master_volume 不是数字）——如果这里变成 .rewritable，"
                        + "整条『读得动写不动』的 divergence 就不存在了，got"
                        + " \(probeConfigRewritable(configFile: configFile))")
                return
            }
        }
    }

    suite("合成矩阵：文件不存在时，读写两轴的答案必须一致地『没问题』（.notSelected / .absent）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            expect(
                packSelection(configFile: configFile) == .notSelected,
                "got \(packSelection(configFile: configFile))")
            expect(
                probeConfigRewritable(configFile: configFile) == .absent,
                "got \(probeConfigRewritable(configFile: configFile))")
        }
    }

    suite("合成矩阵：一份完全正常的 config —— 读写两轴都必须放行（.selected / .rewritable）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "lofi", "master_volume": 0.5, "events": {} }"#, to: configFile)
            expect(
                packSelection(configFile: configFile) == .selected(packID: "lofi"),
                "got \(packSelection(configFile: configFile))")
            expect(
                probeConfigRewritable(configFile: configFile) == .rewritable,
                "got \(probeConfigRewritable(configFile: configFile))")
        }
    }

    suite(
        "合成矩阵：selected_pack 缺失/坏掉的 config —— 读写两轴必须同时报 .malformed"
            + "（同一份坏文件，两条轴不该有一条独自放行）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "master_volume": 0.5 }"#, to: configFile)

            guard case .malformed = packSelection(configFile: configFile) else {
                expect(false, "got \(packSelection(configFile: configFile))")
                return
            }
            guard case .malformed = probeConfigRewritable(configFile: configFile) else {
                expect(false, "got \(probeConfigRewritable(configFile: configFile))")
                return
            }
        }
    }
}
