import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

// MARK: - PreviewFixtures: single-source-of-truth + exhaustiveness (ENGINEERING.md T14 D1/D3)
//
// `PreviewFixtures` (`ClaudioGUICore`) is the ONE place every sample state VALUE the state
// gallery (`ClaudioGUI/StateGalleryView.swift`, T14 D2) renders is constructed. This suite
// pins the RUNTIME shape of each fixture array — that every case (and, for the two-level
// DropZoneState/DropRejectionReason pair, every reason) actually appears — on top of
// `PreviewFixtures`'s own compile-time exhaustive `switch`es (which only guarantee "a human
// wrote a branch for this case somewhere", not "the fixture ARRAY itself includes a sample of
// it"). Together (T14 acceptance criterion 3): a new enum case fails THIS PACKAGE's build
// first (`PreviewFixtures`'s guards, plus every other non-`default` `switch` over these four
// types), and even if a human adds just enough of a branch to compile without also adding a
// fixture, this suite's counts/combinations catch that gap at runtime.
//
// Local label functions below (`onboardingStateLabel`, etc.) are deliberately this suite's
// OWN small exhaustive mappings — not a reuse of `PreviewFixtures`'s internal
// `_coverage(_:)` helpers — mirroring `OnboardingStateSuite.swift`'s own `debugLabel(for:)`
// pattern already established in this file's neighbors: production code never needs a
// state → debug-string mapping, so it stays test-only, duplicated per suite rather than
// promoted to `ClaudioGUICore`'s public surface just for a test to consume.

@MainActor
func runPreviewFixturesSuites() {
    suite("PreviewFixtures supplies the complete About state gallery values") {
        expect(
            PreviewFixtures.aboutBundleFacts.brandName == "Orbit Zero"
                && PreviewFixtures.aboutBundleFacts.productName == "claudi0",
            "About identity fixture must come from the canonical PreviewFixtures catalog")
        expect(
            PreviewFixtures.aboutBundledResources.map(\.kind)
                == AboutBundledResourceKind.allCases
                && PreviewFixtures.aboutBundledResources.allSatisfy { $0.url != nil },
            "About resource fixtures must cover every bundled resource kind")
        expect(
            PreviewFixtures.aboutPathFacts.map(\.kind) == AboutPathKind.allCases
                && PreviewFixtures.aboutPathFacts.allSatisfy { $0.exists },
            "About path fixtures must cover every safe existence fact")
        expect(
            PreviewFixtures.aboutSurfaceFacts.map(\.surface)
                == HostID.productVisibleCases.map(\.surfaceID)
                && PreviewFixtures.aboutSurfaceFacts.map(\.state)
                    == [.ready, .awaitingActivation, .legacy],
            "About Surface fixtures must follow the product registry and cover distinct states")
    }

    // Replaces the former `expect(true, ...)` tautology (T14 review 修复②), which could never
    // fail yet still counted as a check. `assertExhaustive()` now RETURNS the `family.case`
    // labels its state-family guards and all-product scenario catalog actually visited, so this
    // compares that set against
    // the complete expected roster: a fixture array that stops covering one of its enum's cases
    // (a case whose `switch` branch exists but is never REACHED — which compiles perfectly)
    // turns this red.
    suite("PreviewFixtures.assertExhaustive() visits every case plus all-product scenarios") {
        let visited = PreviewFixtures.assertExhaustive()
        let expected: Set<String> = [
            "onboarding.claudeCodeNotInstalled", "onboarding.helperMissing",
            "onboarding.settingsNotWritable", "onboarding.settingsParseFailure",
            "onboarding.notInstalled", "onboarding.installed",
            // T17 —— 第五族：CTA 动作自身的状态。少了它，「进行中的 CTA」与「失败的 CTA」这两个
            // 新视觉态**从来不会被任何一帧渲染**，而这条断言仍然全绿（因为 onboardingStates 依然
            // 完美覆盖它自己那六个 case）——正是 /ship 收口记录 ③ 那次翻车的形状。
            "onboardingAction.idle",
            "onboardingAction.running.takeOver", "onboardingAction.running.disconnect",
            "onboardingAction.failed.withDetail", "onboardingAction.failed.noDetail",
            // T17f —— 「我替你做主」的告知。三个变体各渲染出不同的东西（一行搬走 / 一行换包 /
            // 两行叠着），所以是三个 label、三帧。**注意这份名册是唯一真正的闸门**：
            // `assertExhaustive()` 的比较是 `visited == expected`，若我只加了 coverage 分支（编译器
            // 强制的）而**没加 fixture**，新 label 压根不会进 `visited`，`expected` 不变 → 全绿，
            // 而那三个视觉态一帧都没渲染过。名册与 fixture 必须同时加，缺一个就红。
            "onboardingAction.reported.salvaged",
            "onboardingAction.reported.repaired",
            "onboardingAction.reported.multiple",
            "dropZone.idle", "dropZone.hover", "dropZone.success",
            "dropZone.reject.oversize", "dropZone.reject.nonWhitelistFormat",
            "dropZone.reject.pathTraversal", "dropZone.reject.overDuration",
            "dropZone.reject.builtinReadOnly", "dropZone.reject.copyFailed",
            "dropZone.reject.lockBusy", "dropZone.reject.lockFailed",
            "coverage.present", "coverage.unmapped", "coverage.broken",
            "packCard.complete", "packCard.partial", "packCard.broken",
            "panelPack.loading", "panelPack.pinned.one", "panelPack.pinned.four",
            "panelPack.noPinned", "panelPack.noPacks", "panelPack.readFailed",
            "interfaceText.compact", "interfaceText.standard",
            "interfaceText.large", "interfaceText.maximum",
            "settingsRoute.general", "settingsRoute.integrations",
            "settingsRoute.events-and-sounds", "settingsRoute.notifications",
            "settingsRoute.display", "settingsRoute.sounds", "settingsRoute.usage",
            "settingsRoute.shortcuts", "settingsRoute.about",
            "settingsRouteFailure.invalid-surface",
            "settingsRouteFailure.stale-surface",
            "settingsRouteFailure.stale-sound-scope",
            "settingsRouteFailure.stale-event",
            "settingsRouteFailure.invalid-sound-pack-id",
            "settingsRouteFailure.stale-sound-pack",
            "settingsExperience.general.ready",
            "settingsExperience.general.permission-required",
            "settingsExperience.general.write-failed",
            "settingsExperience.notifications.ready",
            "settingsExperience.notifications.permission-required",
            "settingsExperience.notifications.stale",
            "settingsExperience.notifications.write-failed",
            "settingsExperience.display.ready",
            "settingsExperience.usage.loading",
            "settingsExperience.usage.ready",
            "settingsExperience.usage.empty",
            "settingsExperience.usage.stale",
            "settingsExperience.usage.unreadable",
            "settingsExperience.usage.write-failed",
            "settingsExperience.shortcuts.ready",
            "settingsExperience.shortcuts.empty",
            "settingsExperience.shortcuts.write-failed",
            "settingsExperience.about.ready",
            "settingsExperience.about.empty",
            "settingsExperience.about.write-failed",
            // 第六族（PLAN-MASTER-VOLUME.md D33/D38）：主音量控件行的展示态。少了它，写失败之后的
            // 「行 + 错误行」组合帧——D16「音量 0 = 全局静音」这类最难手动复现的态——落地前零仓库内
            // 视觉验证，而这条断言仍会全绿（因为其余五族依然完美覆盖它们自己的 case）。
            "masterVolume.value", "masterVolume.failed",
            "hostIntegration.all-products-disconnected",
            "hostIntegration.claude-only",
            "hostIntegration.codex-only",
            "hostIntegration.all-products-connected",
            "hostIntegration.codex-awaiting",
            "hostIntegration.claude-legacy",
            "hostIntegration.codex-normal-4-of-5",
            "hostIntegration.partial-single-degraded",
            "hostIntegration.shared-runtime-failure",
            "hostIntegration.single-side-connection-failure",
            "workBuddyVisual.workbuddy.disconnected",
            "workBuddyVisual.workbuddy.awaiting",
            "workBuddyVisual.workbuddy.task-start-current",
            "workBuddyVisual.workbuddy.two-bindings-current",
            "workBuddyVisual.workbuddy.conflict",
            "workBuddyVisual.workbuddy.repaired-awaiting",
            "workBuddyVisual.workbuddy.disconnected-after-action",
            "eventHostIndicator.full-color",
            "eventHostIndicator.mixed",
            "eventHostIndicator.all-gray",
            "eventHostIndicator.legacy",
            "eventHostIndicator.awaiting-narrow",
            "eventRowLayout.zh-Hans-compact",
            "eventRowLayout.zh-Hans-standard",
            "eventRowLayout.zh-Hans-large",
            "eventRowLayout.zh-Hans-maximum",
            "eventRowLayout.en-compact",
            "eventRowLayout.en-standard",
            "eventRowLayout.en-large",
            "eventRowLayout.en-maximum",
        ]
        expect(
            visited == expected,
            "the shipped fixtures must exercise every state case and all-product scenario;"
                + " missing \(expected.subtracting(visited)), unexpected \(visited.subtracting(expected))"
        )
    }

    // MARK: - OnboardingState: all 6 cases

    suite("PreviewFixtures.onboardingStates covers all 6 OnboardingState cases exactly") {
        expect(
            PreviewFixtures.onboardingStates.count == 6,
            "expected exactly 6 onboarding fixtures (one per case), got"
                + " \(PreviewFixtures.onboardingStates.count)")
        let labels = Set(PreviewFixtures.onboardingStates.map(onboardingStateLabel))
        expect(
            labels
                == [
                    "claudeCodeNotInstalled", "helperMissing", "settingsNotWritable",
                    "settingsParseFailure", "notInstalled", "installed",
                ],
            "onboardingStates must cover exactly the 6 OnboardingState cases, got \(labels)")
    }

    // MARK: - DropZoneState: idle/hover/success + a .reject for each of 6 reasons

    suite(
        "PreviewFixtures.dropZoneStates covers .idle/.hover/.success and every DropRejectionReason case"
    ) {
        let states = PreviewFixtures.dropZoneStates
        expect(states.contains(.idle), "dropZoneStates must include .idle")
        expect(states.contains(.hover), "dropZoneStates must include .hover")
        expect(
            states.contains { if case .success = $0 { return true } else { return false } },
            "dropZoneStates must include a .success case")

        let rejectReasonLabels = Set(
            states.compactMap { state -> String? in
                guard case .reject(let reason) = state else { return nil }
                return dropRejectionReasonLabel(reason)
            })
        expect(
            rejectReasonLabels
                == [
                    "oversize", "nonWhitelistFormat", "pathTraversal", "overDuration",
                    "builtinReadOnly", "copyFailed", "lockBusy", "lockFailed",
                ],
            "dropZoneStates must include a .reject for every DropRejectionReason case, got"
                + " \(rejectReasonLabels)")
    }

    suite("PreviewFixtures.dropZoneStates' .success payload is exactly sampleImportedAudioFile") {
        guard case .success(let file) = PreviewFixtures.dropZoneStates.last else {
            expect(false, "the last dropZoneStates fixture must be .success(...)")
            return
        }
        expect(
            file == PreviewFixtures.sampleImportedAudioFile,
            "the gallery's .success frame must render the SAME ImportedAudioFile value this"
                + " suite (and any other consumer) reads from PreviewFixtures — single source,"
                + " not a second copy")
    }

    // MARK: - EventRow: CoverageState × enabled, every combination

    suite("PreviewFixtures.eventRows covers every CoverageState case × enabled (true and false)") {
        let combos = Set(
            PreviewFixtures.eventRows.map { row in
                "\(coverageStateLabel(row.coverage))-\(row.enabled)"
            })
        let expected: Set<String> = [
            "present-true", "present-false",
            "unmapped-true", "unmapped-false",
            "broken-true", "broken-false",
        ]
        expect(
            combos == expected,
            "eventRows must cover every CoverageState × enabled combination exactly, got \(combos)")
    }

    // MARK: - EventRow: the SECOND axis — every Event (T14 review 修复①)
    //
    // `CoverageState × enabled` was the only axis anything pinned, and `Event` — the axis this
    // app is ABOUT — was never checked at all: the shipped fixtures used only stop/stopFailure/
    // notification, so SubagentStop's indigo glyph, its display name and its tile color were
    // rendered exactly zero times by the repo's "exhaustive visual truth source". Driven off
    // `Event.allCases` (compiler-synthesized), not a hand-written list, so a fifth event turns
    // this red without anyone needing to remember this file exists.

    suite(
        "PreviewFixtures.eventRows covers every Event case (the gallery is the EXHAUSTIVE visual truth source — an unrendered event is an unreviewed event)"
    ) {
        let events = Set(PreviewFixtures.eventRows.map(\.event))
        expect(
            events == Set(Event.allCases),
            "eventRows must render every Event at least once; missing"
                + " \(Set(Event.allCases).subtracting(events).map(\.cliName).sorted())")
    }

    suite(
        "PreviewFixtures.eventHostIndicatorScenarios covers full/mixed/gray/legacy/awaiting chip states"
    ) {
        let scenarios = PreviewFixtures.eventHostIndicatorScenarios
        expect(
            scenarios.map(\.id)
                == ["full-color", "mixed", "all-gray", "legacy", "awaiting-narrow"],
            "宿主 Logo 展柜必须精确覆盖五个批准状态，实得 \(scenarios.map(\.id))")

        func indicators(_ id: String) -> [EventHostIndicatorPresentation] {
            guard let scenario = scenarios.first(where: { $0.id == id }) else { return [] }
            return eventHostIndicatorPresentations(
                event: scenario.row.event,
                matrix: hostCapabilityMatrixPresentation(from: scenario.state.matrix))
        }

        expect(
            indicators("full-color").allSatisfy(\.state.usesActiveColor),
            "full-color 帧必须三枚产品 Logo 都彩色")
        expect(
            indicators("mixed").map(\.state) == [.unsupported, .connected, .unsupported],
            "mixed 帧必须按视觉序显示 Codex 灰色、Claude 彩色、WorkBuddy 灰色")
        expect(
            indicators("all-gray").allSatisfy { !$0.state.usesActiveColor },
            "all-gray 帧必须三枚产品 Logo 都灰色")
        expect(
            indicators("legacy").contains(where: { $0.state == .legacy }),
            "legacy 帧必须真的投影旧版连接")
        expect(
            indicators("awaiting-narrow").contains(where: { $0.state == .awaitingActivation }),
            "awaiting 帧必须真的投影待激活")
        expect(
            scenarios.first(where: { $0.id == "full-color" })?.adaptation.rowWrapsToTwoLines
                == false,
            "全彩帧必须检查标准单行布局")
        expect(
            scenarios.first(where: { $0.id == "awaiting-narrow" })?.adaptation
                .rowWrapsToTwoLines == true,
            "待激活帧必须检查窄版两行布局")
        expect(
            scenarios.first(where: { $0.id == "full-color" })?.title.contains("Logo 12pt") == true
                && scenarios.first(where: { $0.id == "awaiting-narrow" })?.title
                    .contains("Logo 12pt") == true
                && scenarios.allSatisfy {
                    !$0.title.contains("22pt") && !$0.title.contains("19pt")
                        && !$0.title.contains("18pt")
                },
            "Preview fixture 描述必须统一使用小标签 12pt Logo，不能留下旧尺寸")
    }

    suite(
        "PreviewFixtures.eventRowLayoutScenarios covers 2 languages × 4 sizes × 3 coverage states"
    ) {
        let scenarios = PreviewFixtures.eventRowLayoutScenarios
        expect(scenarios.count == 8, "事件行 C 布局必须恰好有 8 个语言×字号面板")

        let languageAndSize = Set(
            scenarios.map {
                "\($0.language.rawValue)-\($0.interfaceTextSize.rawValue)"
            })
        let expectedLanguageAndSize = Set(
            ClaudioAppLanguage.allCases.flatMap { language in
                ClaudioInterfaceTextSize.allCases.map { size in
                    "\(language.rawValue)-\(size.rawValue)"
                }
            })
        expect(
            languageAndSize == expectedLanguageAndSize,
            "事件行 C 布局缺少语言×字号组合：\(expectedLanguageAndSize.subtracting(languageAndSize))")

        for scenario in scenarios {
            expect(
                Set(scenario.samples.map { coverageStateLabel($0.row.coverage) })
                    == ["present", "unmapped", "broken"],
                "每个面板必须同帧混排 present/unmapped/broken：\(scenario.id)")
            expect(
                scenario.samples.first?.row.event == .stopFailure,
                "每个字号与语言帧都必须渲染最长英文标题 Execution interrupted")

            let disconnectedSample = scenario.samples.first {
                if case .unmapped = $0.row.coverage { return true }
                return false
            }
            let disconnectedIndicators =
                disconnectedSample.map {
                    eventHostIndicatorPresentations(
                        event: $0.row.event,
                        matrix: hostCapabilityMatrixPresentation(from: $0.state.matrix))
                } ?? []
            expect(
                !disconnectedIndicators.isEmpty
                    && disconnectedIndicators.allSatisfy { indicator in
                        let implemented =
                            HostCapabilityCatalog.binding(
                                host: indicator.host,
                                event: disconnectedSample!.row.event)?.isAudibleCapability == true
                        return indicator.state == (implemented ? .notConnected : .unsupported)
                    },
                "unmapped 样例必须区分已实现能力未连接与未实现能力：\(scenario.id)")
        }

        for size in ClaudioInterfaceTextSize.allCases {
            let layouts =
                scenarios
                .filter { $0.interfaceTextSize == size }
                .map(\.adaptation.eventActionsMoveBelow)
            let expected = size == .maximum
            expect(
                layouts.count == ClaudioAppLanguage.allCases.count
                    && layouts.allSatisfy { $0 == expected },
                "\(size.rawValue) 的双语动作布局错误：\(layouts)")
        }
    }

    // MARK: - PackCard: PackCardState × isSelected, every combination — plus the coverage
    // track's own event axis (T4: `PackGalleryView` renders `Event.allCases` on every card whose
    // `packRowTrailingSlot(for:)` resolves to `.track` — i.e. `.complete`/`.partial` — styled
    // present-or-absent; a `.broken` card renders a status row instead and reaches no track at
    // all, so its `presentEvents` must NOT count toward this exhaustiveness check).

    suite(
        "PreviewFixtures.packCards' coverage track renders every Event in BOTH present and absent styles (scoped to .track-resolving cards — .broken renders no track at all)"
    ) {
        let trackCards = PreviewFixtures.packCards.filter {
            packRowTrailingSlot(for: $0.state) == .track
        }
        expect(
            trackCards.count == 4,
            "fixture premise: exactly the two .complete + two .partial cards resolve to .track,"
                + " got \(trackCards.count)")

        let present = trackCards.reduce(into: Set<Event>()) {
            $0.formUnion($1.presentEvents)
        }
        expect(
            present == Set(Event.allCases),
            "every event must appear PRESENT on at least one .track-resolving card (the"
                + " .complete cards), missing \(Set(Event.allCases).subtracting(present).map(\.cliName).sorted())"
        )

        let absent = trackCards.reduce(into: Set<Event>()) { accumulated, card in
            accumulated.formUnion(Set(Event.allCases).subtracting(card.presentEvents))
        }
        expect(
            absent == Set(Event.allCases),
            "every event must appear ABSENT on at least one .track-resolving card (the .partial"
                + " cards — .broken cards no longer render a track, so they don't count), missing"
                + " \(Set(Event.allCases).subtracting(absent).map(\.cliName).sorted())")
    }

    // MARK: - MasterVolumeState (PLAN-MASTER-VOLUME.md D33/D38): 6 fixtures, both cases covered,
    // including at least one 「行 + 错误行」组合帧 (D39) — the hardest-to-reproduce-by-hand state.

    suite(
        "PreviewFixtures.masterVolumeStates covers both MasterVolumeState cases, exactly 6 fixtures (D38)"
    ) {
        expect(
            PreviewFixtures.masterVolumeStates.count == 6,
            "D38 pins the gallery's master-volume family at exactly 6 frames, got"
                + " \(PreviewFixtures.masterVolumeStates.count)")
        let labels = Set(
            PreviewFixtures.masterVolumeStates.map { state -> String in
                switch state {
                case .value: "value"
                case .failed: "failed"
                }
            })
        expect(
            labels == ["value", "failed"],
            "masterVolumeStates must cover both MasterVolumeState cases, got \(labels)")
        expect(
            PreviewFixtures.masterVolumeStates.contains(.value(0.0)),
            "D16 pins volume == 0 as a legal, non-disabled state (global mute) — it must appear as"
                + " its own frame, not be silently folded away")
    }

    suite("PreviewFixtures.packCards covers every PackCardState case × isSelected (true and false)")
    {
        let combos = Set(
            PreviewFixtures.packCards.map { card in
                "\(packCardStateLabel(card.state))-\(card.isSelected)"
            })
        let expected: Set<String> = [
            "complete-true", "complete-false",
            "partial-true", "partial-false",
            "broken-true", "broken-false",
        ]
        expect(
            combos == expected,
            "packCards must cover every PackCardState × isSelected combination exactly, got \(combos)"
        )
    }

    suite(
        "PreviewFixtures covers panel pack loading/four-result rendering plus 1-row/4-row density and all text sizes"
    ) {
        expect(
            PreviewFixtures.panelPackSectionStates.count == 6,
            "包区域必须包含加载、pinned 1 行/4 行、无固定、无包、读取失败六帧")
        let pinnedCounts = PreviewFixtures.panelPackSectionStates.compactMap { state -> Int? in
            guard case .pinned(let cards) = state else { return nil }
            return cards.count
        }
        expect(pinnedCounts == [1, 4], "固定包密度必须覆盖 1 与 4 行，实得 \(pinnedCounts)")
        expect(
            PreviewFixtures.interfaceTextSizes == ClaudioInterfaceTextSize.allCases,
            "state gallery 必须逐档渲染 Claudio 的全部四档界面文字")
    }

    suite("PreviewFixtures.settingsRouteScenarios pins the fixed nine-slot route gallery") {
        let scenarios = PreviewFixtures.settingsRouteScenarios
        expect(scenarios.count == 9, "统一设置 gallery 必须恰好有九个 route slot")
        expect(
            scenarios.map(\.destination) == SettingsDestination.allCases,
            "统一设置 gallery 必须按固定 sidebar 顺序覆盖全部目的页")
        expect(
            Set(scenarios.map(\.id)).count == scenarios.count,
            "统一设置 gallery scenario ID 必须唯一")
        expect(
            scenarios.allSatisfy { $0.route.destination == $0.destination },
            "每个 gallery route 必须保留其对应目的页")
        expect(
            scenarios.allSatisfy {
                resolveSettingsRoute(
                    $0.route,
                    availability: PreviewFixtures.settingsRouteAvailability
                ).failure == nil
            },
            "九个目的页基础槽位必须全部呈现 ready route")
    }

    suite("PreviewFixtures.settingsRouteFailureScenarios covers every visible failure case") {
        let scenarios = PreviewFixtures.settingsRouteFailureScenarios
        let expectedIDs = [
            "invalid-surface", "stale-surface", "stale-sound-scope", "stale-event",
            "invalid-sound-pack-id", "stale-sound-pack",
        ]
        expect(scenarios.map(\.id) == expectedIDs, "统一设置 gallery 必须覆盖全部六种失败态")
        expect(
            Set(scenarios.map(\.id)).count == scenarios.count,
            "统一设置失败 gallery scenario ID 必须唯一")
        for scenario in scenarios {
            let resolution = resolveSettingsRoute(
                scenario.route,
                availability: scenario.availability)
            expect(
                resolution.failure == scenario.expectedFailure,
                "\(scenario.id) 必须解析为其共享 fixture 指定的失败态")
            expect(
                resolution.route == scenario.route,
                "\(scenario.id) 必须原样保留请求路由而不回退")
        }
    }

    suite("PreviewFixtures.settingsExperienceScenarios pins six production destinations") {
        let scenarios = PreviewFixtures.settingsExperienceScenarios
        expect(
            scenarios == PreviewFixtures.SettingsExperienceScenario.allCases,
            "基础设置 gallery 必须由 enum roster 完整驱动")
        expect(
            Set(scenarios.map(\.destination))
                == [.general, .notifications, .display, .usage, .shortcuts, .about],
            "基础设置 gallery 必须覆盖通用、通知、显示、用量、快捷键、关于六页")
        expect(
            scenarios.map(\.rawValue).contains("usage.loading")
                && scenarios.map(\.rawValue).contains("usage.empty")
                && scenarios.map(\.rawValue).contains("usage.stale")
                && scenarios.map(\.rawValue).contains("usage.unreadable")
                && scenarios.map(\.rawValue).contains("notifications.permission-required")
                && scenarios.map(\.rawValue).contains("notifications.stale")
                && scenarios.map(\.rawValue).contains("about.write-failed"),
            "gallery roster 必须保留 loading/empty/unreadable/permission/stale/write-failed 代表态")
        expect(
            PreviewFixtures.SettingsExperienceScenario.usageUnreadable.profile.usage
                == .unreadable
                && PreviewFixtures.SettingsExperienceScenario.usageStale.profile.usage == .stale
                && PreviewFixtures.SettingsExperienceScenario.notificationsStale.profile
                    .notifications == .stale,
            "gallery scenario 名必须映射真实 fixture 语义，stale 必须保留旧快照而非冒充 unreadable")
    }

    // MARK: - All-product integration scenarios

    suite("PreviewFixtures.hostIntegrationScenarios pins the complete 10-state product roster") {
        let expectedIDs = [
            "all-products-disconnected",
            "claude-only",
            "codex-only",
            "all-products-connected",
            "codex-awaiting",
            "claude-legacy",
            "codex-normal-4-of-5",
            "partial-single-degraded",
            "shared-runtime-failure",
            "single-side-connection-failure",
        ]
        let scenarios = PreviewFixtures.hostIntegrationScenarios
        expect(
            scenarios.map(\.id) == expectedIDs,
            "全部产品 gallery 必须按稳定顺序覆盖 10 个产品态，实得 \(scenarios.map(\.id))")
        expect(
            Set(scenarios.map(\.id)).count == scenarios.count,
            "全部产品 gallery scenario ID 必须唯一")
    }

    suite("Host integration fixtures: every frame is a catalog-driven dynamic AudibilityMatrix") {
        for scenario in PreviewFixtures.hostIntegrationScenarios {
            expect(
                scenario.state.snapshots.map(\.host) == HostID.productVisibleCases,
                "\(scenario.id) 必须同时带全部已出货宿主快照")
            let presentation = hostCapabilityMatrixPresentation(from: scenario.state.matrix)
            expect(
                presentation.hostColumns == [.codex, .claudeCode, .workBuddy]
                    && presentation.rows.allSatisfy {
                        $0.cells.map(\.host) == [.codex, .claudeCode, .workBuddy]
                    },
                "\(scenario.id) preview 必须服从生产 Product → Surface 视觉序")
            expect(
                scenario.state.matrix.rows.map(\.event) == Event.allCases,
                "\(scenario.id) 必须由 Event.allCases 生成五行")
            for row in scenario.state.matrix.rows {
                expect(
                    row.cells.map(\.host) == HostID.productVisibleCases,
                    "\(scenario.id)/\(row.event) 必须由 registry 生成全部格子")
                for cell in row.cells {
                    expect(
                        cell.binding
                            == HostCapabilityCatalog.binding(
                                host: cell.host, event: row.event),
                        "\(scenario.id)/\(cell.host)/\(row.event) 必须直接复用 catalog binding")
                }
            }
        }
    }

    suite(
        "Host integration fixtures: 4/5 stays normal; awaiting, legacy and failures stay distinct"
    ) {
        func scenario(_ id: String) -> PreviewFixtures.HostIntegrationScenario? {
            PreviewFixtures.hostIntegrationScenarios.first(where: { $0.id == id })
        }

        let disconnected = scenario("all-products-disconnected")
        expect(
            disconnected?.state.matrix.summary(for: .claudeCode)
                == .notConnected(supported: 5, total: 5)
                && disconnected?.state.matrix.summary(for: .codex)
                    == .notConnected(supported: 4, total: 5),
            "全部产品未连接必须保留各来源自己的能力事实")
        let claudeOnly = scenario("claude-only")
        expect(
            claudeOnly?.state.matrix.summary(for: .claudeCode)
                == .ready(supported: 5, total: 5)
                && claudeOnly?.state.matrix.summary(for: .codex)
                    == .notConnected(supported: 4, total: 5),
            "Claude-only 必须一侧 ready、一侧 notConnected")
        let codexOnly = scenario("codex-only")
        expect(
            codexOnly?.state.matrix.summary(for: .claudeCode)
                == .notConnected(supported: 5, total: 5)
                && codexOnly?.state.matrix.summary(for: .codex)
                    == .ready(supported: 4, total: 5),
            "Codex-only 必须一侧 notConnected、一侧正常 4/5 ready")
        let allProductsConnected = scenario("all-products-connected")
        expect(
            allProductsConnected?.state.matrix.summary(for: .claudeCode)
                == .ready(supported: 5, total: 5)
                && allProductsConnected?.state.matrix.summary(for: .codex)
                    == .ready(supported: 4, total: 5)
                && allProductsConnected?.state.matrix.summary(for: .workBuddy)
                    == .ready(supported: 2, total: 5),
            "全部产品连接必须同时保留 Claude 5/5、Codex 4/5 与 WorkBuddy 2/5")

        let codexNormal = scenario("codex-normal-4-of-5")
        expect(
            codexNormal?.state.matrix.summary(for: .codex)
                == .ready(supported: 4, total: 5),
            "Codex 4/5 必须是中性成功 ready")
        expect(
            codexNormal?.state.matrix.cell(host: .codex, event: .stopFailure)?.state
                == .unsupported,
            "Codex 的执行中断格必须严格 unsupported，不得降级映射")

        expect(
            scenario("codex-awaiting")?.state.matrix.summary(for: .codex)
                == .awaitingActivation(supported: 4, total: 5),
            "Codex 等待 /hooks 确认必须独立于已连接")
        expect(
            scenario("claude-legacy")?.state.matrix.summary(for: .claudeCode)
                == .legacy(supported: 4, total: 5),
            "Claude legacy 必须只统计旧安装器实际写入的四个事件")

        if case .needsAttention = scenario("partial-single-degraded")?.state.matrix.summary(
            for: .claudeCode)
        {
            expect(true, "partial 一侧必须 degraded")
        } else {
            expect(false, "partial 一侧必须 degraded")
        }
        expect(
            scenario("partial-single-degraded")?.state.matrix.summary(for: .codex)
                == .ready(supported: 4, total: 5),
            "一侧 degraded 不得冻结另一侧")

        let sharedFailure = scenario("shared-runtime-failure")
        for host in HostID.productVisibleCases {
            if case .needsAttention = sharedFailure?.state.matrix.summary(for: host) {
                expect(true, "共享 runtime 损坏必须影响 \(host.displayName)")
            } else {
                expect(false, "共享 runtime 损坏必须影响 \(host.displayName)")
            }
        }

        let oneSideFailure = scenario("single-side-connection-failure")
        if case .needsAttention = oneSideFailure?.state.matrix.summary(for: .claudeCode) {
            expect(true, "连接失败侧必须 needsAttention")
        } else {
            expect(false, "连接失败侧必须 needsAttention")
        }
        expect(
            oneSideFailure?.state.matrix.summary(for: .codex)
                == .ready(supported: 4, total: 5),
            "单侧连接失败不得传染另一侧")
    }
}

/// Exhaustive over every ``OnboardingState`` case — no `default:` (test-only, mirrors
/// `OnboardingStateSuite.swift`'s own `debugLabel(for:)`).
private func onboardingStateLabel(_ state: OnboardingState) -> String {
    switch state {
    case .claudeCodeNotInstalled: "claudeCodeNotInstalled"
    case .helperMissing: "helperMissing"
    case .settingsNotWritable: "settingsNotWritable"
    case .settingsParseFailure: "settingsParseFailure"
    case .notInstalled: "notInstalled"
    case .installed: "installed"
    }
}

/// Exhaustive over every ``DropRejectionReason`` case — no `default:`.
private func dropRejectionReasonLabel(_ reason: DropRejectionReason) -> String {
    switch reason {
    case .oversize: "oversize"
    case .nonWhitelistFormat: "nonWhitelistFormat"
    case .pathTraversal: "pathTraversal"
    case .overDuration: "overDuration"
    case .builtinReadOnly: "builtinReadOnly"
    case .copyFailed: "copyFailed"
    case .lockBusy: "lockBusy"
    case .lockFailed: "lockFailed"
    }
}

/// Exhaustive over every ``CoverageState`` case — no `default:`.
private func coverageStateLabel(_ state: CoverageState) -> String {
    switch state {
    case .present: "present"
    case .unmapped: "unmapped"
    case .broken: "broken"
    }
}

/// Exhaustive over every ``PackCardState`` case — no `default:`.
private func packCardStateLabel(_ state: PackCardState) -> String {
    switch state {
    case .complete: "complete"
    case .partial: "partial"
    case .broken: "broken"
    }
}
