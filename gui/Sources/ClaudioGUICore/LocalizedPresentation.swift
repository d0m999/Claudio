import ClaudioCore
import ClaudioLocalization
import Foundation

private func localizedHostSeparator(_ language: ClaudioAppLanguage) -> String {
    language == .english ? ", " : "，"
}

public func localizedHostName(_ host: HostID, language: ClaudioAppLanguage) -> String {
    // These are product/host names, not translatable prose.
    host.displayName
}

public func localizedEventName(_ event: Event, language: ClaudioAppLanguage) -> String {
    let l10n = ClaudioL10n(language: language)
    switch event {
    case .taskStart: return l10n.text(.eventTaskStart)
    case .stop: return l10n.text(.eventStop)
    case .stopFailure: return l10n.text(.eventStopFailure)
    case .notification: return l10n.text(.eventNotification)
    case .subagentStop: return l10n.text(.eventSubagentStop)
    }
}

private func localizedHostReadiness(
    _ row: HostSourceRowPresentation,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    let counts = row.supportedCount.flatMap { supported in
        row.totalCount.map { total in (supported, total) }
    } ?? parseHostCounts(row.readinessText)
    guard let (supported, total) = counts else { return row.readinessText }
    let key: ClaudioL10nKey
    switch row.status {
    case .ready: key = .hostReady
    case .awaitingActivation: key = .hostConfigured
    case .legacy: key = .hostLegacy
    case .notConnected: key = .hostNotConnected
    case .needsAttention: key = .hostNeedsAttention
    }
    return l10n.format(key, Int64(supported), Int64(total))
}

private func parseHostCounts(_ text: String) -> (Int, Int)? {
    guard
        let prefix = text.split(whereSeparator: { $0.isWhitespace }).first,
        let separator = prefix.firstIndex(of: "/"),
        let supported = Int(prefix[..<separator]),
        let total = Int(prefix[prefix.index(after: separator)...])
    else { return nil }
    return (supported, total)
}

private func localizedHostDetail(
    _ row: HostSourceRowPresentation,
    language: ClaudioAppLanguage
) -> String? {
    let l10n = ClaudioL10n(language: language)
    switch row.status {
    case .ready:
        return row.host == .codex ? l10n.text(.hostCodexReadyDetail) : nil
    case .awaitingActivation:
        return row.host == .codex
            ? l10n.text(.hostCodexAwaitingDetail)
            : l10n.text(.hostClaudeAwaitingDetail)
    case .legacy:
        return row.host == .claudeCode
            ? l10n.text(.hostClaudeLegacyDetail)
            : l10n.text(.hostCodexLegacyDetail)
    case .notConnected:
        return nil
    case .needsAttention:
        // This reason is supplied by the host integration manager and is retained as domain
        // data. It must not be guessed or translated by the GUI.
        return row.detailText
    }
}

public func localizedHostSourceRow(
    _ row: HostSourceRowPresentation,
    language: ClaudioAppLanguage
) -> HostSourceRowPresentation {
    let title = localizedHostName(row.host, language: language)
    let readiness = localizedHostReadiness(row, language: language)
    let detail = localizedHostDetail(row, language: language)
    let separator = localizedHostSeparator(language)
    return HostSourceRowPresentation(
        host: row.host,
        title: title,
        readinessText: readiness,
        detailText: detail,
        status: row.status,
        accessibilityLabel: [title, readiness, detail].compactMap { $0 }.joined(separator: separator),
        supportedCount: row.supportedCount,
        totalCount: row.totalCount)
}

public func localizedHostSourceRows(
    _ rows: [HostSourceRowPresentation],
    language: ClaudioAppLanguage
) -> [HostSourceRowPresentation] {
    rows.map { localizedHostSourceRow($0, language: language) }
}

public func localizedCellStatus(
    _ cell: HostCapabilityCellPresentation,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch cell.state {
    case .audible: return l10n.text(.cellAudible)
    case .muted:
        return cell.muteReason == .masterVolumeZero
            ? l10n.text(.cellMasterVolumeZero)
            : l10n.text(.cellMuted)
    case .missingSound: return l10n.text(.cellMissingSound)
    case .notConnected: return l10n.text(.cellNotConnected)
    case .awaitingActivation: return l10n.text(.cellAwaitingActivation)
    case .legacy: return l10n.text(.cellLegacy)
    case .unsupported: return l10n.text(.cellUnsupported)
    case .degraded: return l10n.text(.cellDegraded)
    }
}

private func localizedQualification(
    _ value: String?,
    language: ClaudioAppLanguage
) -> String? {
    guard let value else { return nil }
    if value == "仅授权请求" {
        return language == .english ? "Authorization request only" : value
    }
    return value
}

public func localizedCapabilityCell(
    _ cell: HostCapabilityCellPresentation,
    language: ClaudioAppLanguage
) -> HostCapabilityCellPresentation {
    let host = localizedHostName(cell.host, language: language)
    let event = localizedEventName(cell.event, language: language)
    let status = localizedCellStatus(cell, language: language)
    let qualification = localizedQualification(cell.qualificationText, language: language)
    let separator = localizedHostSeparator(language)
    var clauses = [host, event, status]
    if let qualification { clauses.append(qualification) }
    if let detail = cell.detailText, !detail.isEmpty { clauses.append(detail) }
    return HostCapabilityCellPresentation(
        host: cell.host,
        event: cell.event,
        state: cell.state,
        muteReason: cell.muteReason,
        nativeEventText: cell.nativeEventText,
        qualificationText: qualification,
        statusText: status,
        detailText: cell.detailText,
        accessibilityLabel: clauses.joined(separator: separator))
}

public func localizedCapabilityMatrix(
    _ matrix: HostCapabilityMatrixPresentation,
    language: ClaudioAppLanguage
) -> HostCapabilityMatrixPresentation {
    HostCapabilityMatrixPresentation(
        hostColumns: matrix.hostColumns,
        rows: matrix.rows.map { row in
            HostCapabilityEventRowPresentation(
                event: row.event,
                title: localizedEventName(row.event, language: language),
                cells: row.cells.map { localizedCapabilityCell($0, language: language) })
        })
}

public func localizedEventHostIndicator(
    _ indicator: EventHostIndicatorPresentation,
    language: ClaudioAppLanguage
) -> EventHostIndicatorPresentation {
    EventHostIndicatorPresentation(
        host: indicator.host,
        state: indicator.state,
        compactDisplayName: indicator.compactDisplayName,
        qualificationText: localizedQualification(indicator.qualificationText, language: language))
}

public func localizedEventHostIndicators(
    _ indicators: [EventHostIndicatorPresentation],
    language: ClaudioAppLanguage
) -> [EventHostIndicatorPresentation] {
    indicators.map { localizedEventHostIndicator($0, language: language) }
}

public func localizedEventHostIndicatorStatus(
    _ state: EventHostIndicatorState,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch state {
    case .connected: return l10n.text(.cellAudible)
    case .legacy: return l10n.text(.hostLegacy)
    case .awaitingActivation: return l10n.text(.cellAwaitingActivation)
    case .notConnected: return l10n.text(.hostNotConnected)
    case .needsAttention: return l10n.text(.cellDegraded)
    case .unsupported: return l10n.text(.cellUnsupported)
    }
}

public func localizedHostLatestReceiptText(
    snapshot: HostIntegrationSnapshot,
    language: ClaudioAppLanguage
) -> String? {
    guard let evidence = hostLatestReceiptEvidence(snapshot: snapshot) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: evidence.timestamp)
    return "\(localizedHostName(snapshot.host, language: language)) · "
        + "\(localizedEventName(evidence.event, language: language)) · \(timestamp) · "
        + localizedPlaybackResult(evidence.playbackResult, language: language)
}

public func localizedLatestReceiptText(
    _ text: String?,
    language: ClaudioAppLanguage
) -> String? {
    guard let text, !text.isEmpty else { return nil }
    let pieces = text.components(separatedBy: " · ")
    guard pieces.count >= 4 else { return text }
    let event = Event.allCases.first { $0.displayName == pieces[1] || $0.cliName == pieces[1] }
    let result = [
        HostHookPlaybackResult.played,
        .muted,
        .debounced,
        .notReady,
        .unsupportedEvent,
        .playbackFailed,
    ].first {
        hostHookPlaybackResultDisplayName($0) == pieces[3]
    }
    let localizedHost = pieces[0]
    let localizedEvent = event.map { localizedEventName($0, language: language) } ?? pieces[1]
    let localizedResult = result.map { localizedPlaybackResult($0, language: language) } ?? pieces[3]
    return "\(localizedHost) · \(localizedEvent) · \(pieces[2]) · \(localizedResult)"
}

public func localizedConfigurationSource(
    _ source: String,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    if source == l10n.text(.integrationsManagerProvidedSource)
        || source == ClaudioL10n(language: .zhHans).text(.integrationsManagerProvidedSource)
    {
        return l10n.text(.integrationsManagerProvidedSource)
    }
    return source
}

public func localizedPlaybackResult(
    _ result: HostHookPlaybackResult,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch result {
    case .played: return l10n.text(.hostPlaybackPlayed)
    case .muted: return l10n.text(.hostPlaybackMuted)
    case .debounced: return l10n.text(.hostPlaybackDebounced)
    case .notReady: return l10n.text(.hostPlaybackNotReady)
    case .unsupportedEvent: return l10n.text(.hostPlaybackUnsupported)
    case .playbackFailed: return l10n.text(.hostPlaybackFailed)
    }
}

public func localizedSoundPacksPackAccessibilityLabel(
    displayName: String,
    isActivePack: Bool,
    state: PackCardState,
    license: PackRowLicenseBadge,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    var facts = [displayName]
    if isActivePack { facts.append(l10n.text(.soundPacksPackActive)) }
    switch state {
    case .complete:
        facts.append(l10n.format(.soundPacksPackComplete, Int64(Event.allCases.count)))
    case .partial(let present, let total):
        facts.append(l10n.format(
            .soundPacksPackPartial,
            Int64(present),
            Int64(total),
            Int64(max(0, total - present))))
    case .broken(let reason):
        facts.append(l10n.format(.soundPacksPackBroken, reason))
    }
    switch license {
    case .none: break
    case .cc0: facts.append("CC0")
    case .modified: facts.append(l10n.text(.soundPacksPackModified))
    }
    return facts.joined(separator: language == .english ? ", " : "，")
}

public func localizedSoundPacksEventAccessibilityLabel(
    eventName: String,
    coverage: CoverageState,
    enabled: Bool,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    let enabledFact = enabled ? l10n.text(.eventEnabled) : l10n.text(.eventMuted)
    switch coverage {
    case .present(let fileName):
        return l10n.format(.soundPacksEventPresent, eventName, fileName, enabledFact)
    case .unmapped:
        return l10n.format(.soundPacksEventUnmapped, eventName, enabledFact)
    case .broken(let fileName):
        return l10n.format(.soundPacksEventBroken, eventName, fileName, enabledFact)
    }
}

public func localizedSoundPacksFailureAccessibilityLabel(
    action: String,
    reason: String,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    if action.isEmpty {
        return reason.isEmpty ? l10n.text(.soundPacksOperationFailed) : reason
    }
    return reason.isEmpty ? l10n.format(.soundPacksActionFailed, action, "")
        : l10n.format(.soundPacksActionFailed, action, reason)
}

/// Localized projection for the retained onboarding surface. The core state machine keeps its
/// original Chinese copy for compatibility with existing domain tests; GUI callers must consume
/// this explicit projection so a language change updates an already-rendered card without
/// re-running detection or touching host configuration.
public func localizedOnboardingCopy(
    for state: OnboardingState,
    language: ClaudioAppLanguage
) -> OnboardingCopy {
    let l10n = ClaudioL10n(language: language)
    let source = onboardingCopy(for: state)
    let titleKey: ClaudioL10nKey
    let bodyKey: ClaudioL10nKey
    let primaryKey: ClaudioL10nKey?
    let secondaryKey: ClaudioL10nKey?
    switch state {
    case .claudeCodeNotInstalled:
        titleKey = .onboardingClaudeCodeNotInstalledTitle
        bodyKey = .onboardingClaudeCodeNotInstalledBody
        primaryKey = .onboardingActionRedetect
        secondaryKey = nil
    case .helperMissing:
        titleKey = .onboardingHelperMissingTitle
        bodyKey = .onboardingHelperMissingBody
        primaryKey = .onboardingActionRepair
        secondaryKey = nil
    case .settingsNotWritable:
        titleKey = .onboardingSettingsNotWritableTitle
        bodyKey = .onboardingSettingsNotWritableBody
        primaryKey = .onboardingActionRedetect
        secondaryKey = .onboardingActionRevealReason
    case .settingsParseFailure:
        titleKey = .onboardingSettingsParseFailureTitle
        bodyKey = .onboardingSettingsParseFailureBody
        primaryKey = .onboardingActionRedetect
        secondaryKey = .onboardingActionRevealReason
    case .notInstalled:
        titleKey = .onboardingNotInstalledTitle
        bodyKey = .onboardingNotInstalledBody
        primaryKey = .onboardingActionTakeOver
        secondaryKey = nil
    case .installed:
        titleKey = .onboardingInstalledTitle
        bodyKey = .onboardingInstalledBody
        primaryKey = nil
        secondaryKey = .onboardingActionDisconnect
    }
    return OnboardingCopy(
        title: l10n.text(titleKey),
        body: l10n.text(bodyKey),
        detail: source.detail,
        primaryActionTitle: primaryKey.map(l10n.text),
        secondaryActionTitle: secondaryKey.map(l10n.text))
}

public func localizedOnboardingActionRunningTitle(
    _ action: OnboardingDiskAction,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch action {
    case .takeOver: return l10n.text(.onboardingActionRunningTakeOver)
    case .disconnect: return l10n.text(.onboardingActionRunningDisconnect)
    }
}

/// Projects the user-facing action result without translating the technical detail. The core
/// action state keeps its original message for existing domain/announcement contracts; these
/// stable message families are the product copy owned by the GUI and therefore have explicit
/// catalog entries. Unknown/custom messages remain verbatim domain data.
public func localizedOnboardingActionFailureMessage(
    action: OnboardingDiskAction,
    message: String,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch action {
    case .takeOver:
        if message.hasPrefix("没找到 claudi0 随身带的那个小助手") {
            return l10n.text(.onboardingFailureHelperUnavailable)
        }
        if message.hasPrefix("这一步没能完成") {
            return l10n.text(.onboardingFailureSetup)
        }
    case .disconnect:
        if message.hasPrefix("没能断开：") {
            return l10n.text(.onboardingFailureDisconnectNothing)
        }
        if message.hasPrefix("没能断开") {
            return l10n.text(.onboardingFailureDisconnect)
        }
    }
    return message
}

public func localizedSetupNoticeMessage(
    _ notice: SetupNotice,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch notice {
    case .salvagedPack(let packID, let movedTo):
        return l10n.format(.onboardingNoticeSalvaged, packID, movedTo)
    case .repairedDeadSelection(let removed, let selected):
        return l10n.format(.onboardingNoticeRepaired, removed, selected)
    }
}
