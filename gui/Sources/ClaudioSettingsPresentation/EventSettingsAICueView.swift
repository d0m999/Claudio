import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

@MainActor
package struct EventSettingsAICueServiceCard: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var languageStore: ClaudioPreferences
    let onManageCredential: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    package init(
        viewModel: AICueGenerationViewModel,
        languageStore: ClaudioPreferences,
        onManageCredential: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.languageStore = languageStore
        self.onManageCredential = onManageCredential
    }

    package var body: some View {
        let status = statusPresentation
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .frame(width: 30, height: 30)
                    .background(ClaudioTheme.clay(colorScheme).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.text(.aiCueServiceTitle))
                        .font(ClaudioTheme.font(.body).weight(.semibold))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                    Text(
                        l10n.format(
                            .aiCueServiceSubtitle,
                            l10n.text(viewModel.providerProfile.displayNameKey)
                        )
                    )
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker(
                l10n.text(.aiCueProviderLabel),
                selection: Binding(
                    get: { viewModel.providerProfileID },
                    set: { profileID in
                        try? viewModel.selectProviderProfile(profileID)
                        Task {
                            await viewModel.refreshCredentialStatus()
                        }
                    })
            ) {
                ForEach(viewModel.availableProviderProfiles, id: \.id) { profile in
                    Text(l10n.text(profile.displayNameKey))
                        .tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(
                viewModel.phase == .adopting
                    || viewModel.credentialActivity != .idle
            )
            .accessibilityLabel(l10n.text(.aiCueProviderLabel))
            .accessibilityValue(l10n.text(viewModel.providerProfile.displayNameKey))
            .accessibilityHint(capabilityText)
            .accessibilityIdentifier("event-settings.ai-cue.provider-profile")

            Text(capabilityText)
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("event-settings.ai-cue.provider-capabilities")

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                        .foregroundColor(status.symbolColor)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .font(ClaudioTheme.font(.caption).weight(.medium))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    l10n.text(viewModel.providerProfile.displayNameKey) + " · " + status.text
                )
                .accessibilityIdentifier("event-settings.ai-cue.credential-status")
                Spacer(minLength: 8)
                Button(manageButtonTitle, action: onManageCredential)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.credentialActivity != .idle)
                    .accessibilityLabel(manageButtonTitle)
                    .accessibilityIdentifier("event-settings.ai-cue.credential-manage")
            }
        }
        .padding(12)
        .background(ClaudioTheme.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                .stroke(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.ai-cue.service")
    }

    private var statusPresentation: (text: String, symbol: String, symbolColor: Color) {
        if viewModel.credentialActivity != .idle {
            return (
                l10n.text(aiCueCredentialActivityKey(viewModel.credentialActivity)),
                "clock.arrow.circlepath",
                ClaudioTheme.secondaryText(colorScheme)
            )
        }
        switch viewModel.credentialStatus {
        case nil:
            return (
                l10n.text(.aiCueServiceChecking),
                "clock.arrow.circlepath",
                ClaudioTheme.secondaryText(colorScheme)
            )
        case .missing:
            return (
                l10n.text(.aiCueServiceMissing),
                "key.slash",
                ClaudioTheme.secondaryText(colorScheme)
            )
        case .stored(_, true):
            return (
                l10n.text(.aiCueServicePendingReplacement),
                "arrow.triangle.2.circlepath",
                ClaudioTheme.secondaryText(colorScheme)
            )
        case .stored(.verified, false):
            return (
                l10n.text(.aiCueServiceStoredVerified),
                "checkmark.circle.fill",
                ClaudioTheme.success(colorScheme)
            )
        case .stored(.deferred, false):
            return (
                l10n.text(.aiCueServiceStoredDeferred),
                "clock.badge.checkmark",
                ClaudioTheme.secondaryText(colorScheme)
            )
        case .stored(.rejected, false):
            return (
                l10n.text(.aiCueServiceStoredRejected),
                "xmark.circle.fill",
                ClaudioTheme.error(colorScheme)
            )
        case .unavailable:
            return (
                l10n.text(.aiCueServiceUnavailable),
                "xmark.circle.fill",
                ClaudioTheme.error(colorScheme)
            )
        }
    }

    private var manageButtonTitle: String {
        if case .stored = viewModel.credentialStatus {
            return l10n.text(.aiCueManageKey)
        }
        return l10n.text(.aiCueConfigureKey)
    }

    private var capabilityText: String {
        let modalities = AICueModality.allCases
            .filter(viewModel.providerProfile.supportedModalities.contains)
            .map { l10n.text(aiCueModalityKey($0)) }
            .joined(separator: languageStore.language == .english ? ", " : "，")
        return l10n.format(.aiCueProviderCapabilities, modalities)
    }
}

@MainActor
package struct EventSettingsAICueComposerView: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var languageStore: ClaudioPreferences
    let eventTitle: String
    let playingCandidateID: UUID?
    let adoptionEnabled: Bool
    let adoptionUnavailableHint: String
    let onConfigureCredential: () -> Void
    let onPreviewCandidate: (AICueCandidate) -> Void
    let onAdoptCandidate: (UUID) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    package init(
        viewModel: AICueGenerationViewModel,
        languageStore: ClaudioPreferences,
        eventTitle: String,
        playingCandidateID: UUID?,
        adoptionEnabled: Bool,
        adoptionUnavailableHint: String,
        onConfigureCredential: @escaping () -> Void,
        onPreviewCandidate: @escaping (AICueCandidate) -> Void,
        onAdoptCandidate: @escaping (UUID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.languageStore = languageStore
        self.eventTitle = eventTitle
        self.playingCandidateID = playingCandidateID
        self.adoptionEnabled = adoptionEnabled
        self.adoptionUnavailableHint = adoptionUnavailableHint
        self.onConfigureCredential = onConfigureCredential
        self.onPreviewCandidate = onPreviewCandidate
        self.onAdoptCandidate = onAdoptCandidate
        self.onClose = onClose
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(l10n.format(.aiCueComposerTitle, eventTitle))
                    .font(ClaudioTheme.font(.sectionTitle).weight(.bold))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                Spacer(minLength: 8)
                Button(l10n.text(.commonClose), action: onClose)
                    .buttonStyle(ClaudioCompactButtonStyle())
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .accessibilityLabel(l10n.text(.commonClose))
                    .accessibilityIdentifier("event-settings.ai-cue.close")
            }

            stageIndicator

            if let failure = viewModel.failure {
                errorNotice(aiCueFailureText(failure, l10n: l10n))
            }

            switch viewModel.phase {
            case .editing, .generating:
                descriptionStep
            case .candidatesReady, .adopting:
                candidatesStep
            case .applied:
                appliedStep
            }
        }
        .padding(18)
        .background(ClaudioTheme.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                .stroke(ClaudioTheme.clay(colorScheme).opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.ai-cue.composer")
    }

    private var stageIndicator: some View {
        HStack(spacing: 10) {
            stageLabel(
                l10n.text(.aiCueStageDescription),
                isActive: viewModel.phase == .editing || viewModel.phase == .generating)
            Capsule()
                .fill(ClaudioTheme.hairline(colorScheme))
                .frame(width: 34, height: 1)
                .accessibilityHidden(true)
            stageLabel(
                l10n.text(.aiCueStageCandidates),
                isActive: viewModel.phase == .candidatesReady
                    || viewModel.phase == .adopting
                    || viewModel.phase == .applied)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.ai-cue.stages")
    }

    private func stageLabel(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(ClaudioTheme.font(.caption).weight(.semibold))
            .foregroundColor(
                isActive
                    ? ClaudioTheme.clay(colorScheme)
                    : ClaudioTheme.secondaryText(colorScheme))
    }

    private var descriptionStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.aiCueDescriptionLabel))
                .font(ClaudioTheme.font(.body).weight(.semibold))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Text(l10n.text(.aiCueDescriptionHelp))
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))

            ZStack(alignment: .topLeading) {
                if viewModel.soundDescription.isEmpty {
                    Text(l10n.text(.aiCueDescriptionPlaceholder))
                        .font(ClaudioTheme.font(.body))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme).opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(
                    text: Binding(
                        get: { viewModel.soundDescription },
                        set: { viewModel.updateDescription($0) })
                )
                .font(ClaudioTheme.font(.body))
                .frame(minHeight: 92)
                .padding(4)
                .background(ClaudioTheme.panel(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                        .stroke(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
                )
                .disabled(viewModel.phase == .generating)
                .accessibilityLabel(l10n.text(.aiCueDescriptionLabel))
                .accessibilityHint(l10n.text(.aiCueDescriptionHelp))
                .accessibilityIdentifier("event-settings.ai-cue.description")
            }

            HStack(spacing: 10) {
                Spacer()
                if viewModel.phase == .generating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(l10n.text(.aiCueGenerating))
                    Text(l10n.text(.aiCueGenerating))
                        .font(ClaudioTheme.font(.caption))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    Button(l10n.text(.commonCancel)) {
                        viewModel.returnToDescription()
                    }
                    .accessibilityLabel(l10n.text(.commonCancel))
                    .accessibilityIdentifier("event-settings.ai-cue.cancel-generation")
                } else {
                    Button(l10n.text(.aiCueGenerateCandidates)) {
                        viewModel.startGeneration(locale: languageStore.language.rawValue)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(l10n.text(.aiCueGenerateCandidates))
                    .accessibilityHint(l10n.text(.aiCueGenerateHint))
                    .accessibilityIdentifier("event-settings.ai-cue.generate")
                }
            }

            if viewModel.requiresCredentialConfiguration {
                Button(l10n.text(.aiCueConfigureKey), action: onConfigureCredential)
                    .buttonStyle(.link)
                    .accessibilityLabel(l10n.text(.aiCueConfigureKey))
                    .accessibilityIdentifier("event-settings.ai-cue.configure-required")
            }
        }
    }

    private var candidatesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.text(.aiCueDescriptionSummary))
                        .font(ClaudioTheme.font(.caption).weight(.semibold))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                    Text(viewModel.soundDescription)
                        .font(ClaudioTheme.font(.caption))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Button(l10n.text(.aiCueModifyDescription)) {
                    viewModel.returnToDescription()
                }
                .disabled(viewModel.phase == .adopting)
                .accessibilityLabel(l10n.text(.aiCueModifyDescription))
                .accessibilityIdentifier("event-settings.ai-cue.modify-description")
            }
            .padding(10)
            .background(ClaudioTheme.panel(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))

            Text(l10n.text(.aiCueNameLabel))
                .font(ClaudioTheme.font(.body).weight(.semibold))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            TextField(
                l10n.text(.aiCueNameLabel),
                text: Binding(
                    get: { viewModel.displayName },
                    set: { viewModel.updateDisplayName($0) })
            )
            .textFieldStyle(.roundedBorder)
            .disabled(viewModel.phase == .adopting)
            .accessibilityLabel(l10n.text(.aiCueNameLabel))
            .accessibilityHint(l10n.text(.aiCueNameHelp))
            .accessibilityIdentifier("event-settings.ai-cue.name")
            Text(l10n.text(.aiCueNameHelp))
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))

            if let generation = viewModel.generation {
                VStack(spacing: 8) {
                    ForEach(generation.candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }

            HStack {
                Text(l10n.text(.aiCueRegenerate))
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityHidden(true)
                Spacer()
                Button(l10n.text(.aiCueRegenerate)) {
                    viewModel.startGeneration(locale: languageStore.language.rawValue)
                }
                .disabled(viewModel.phase == .adopting)
                .accessibilityLabel(l10n.text(.aiCueRegenerate))
                .accessibilityHint(l10n.text(.aiCueGenerateHint))
                .accessibilityIdentifier("event-settings.ai-cue.regenerate")
            }
        }
    }

    private func candidateRow(_ candidate: AICueCandidate) -> some View {
        HStack(spacing: 10) {
            Button {
                onPreviewCandidate(candidate)
            } label: {
                Image(systemName: playingCandidateID == candidate.id ? "stop.fill" : "play.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .accessibilityLabel(candidatePreviewLabel(candidate))
            .accessibilityIdentifier(
                "event-settings.ai-cue.candidate.\(candidate.variant.rawValue).preview")

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    localizedAICueCandidateTitle(
                        candidate.variant,
                        language: languageStore.language)
                )
                .font(ClaudioTheme.font(.body).weight(.semibold))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                Text(candidateDuration(candidate))
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }

            Spacer(minLength: 8)

            if viewModel.adoptingCandidateID == candidate.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(l10n.text(.aiCueUseForEvent))
            }
            Button(l10n.text(.aiCueUseForEvent)) {
                onAdoptCandidate(candidate.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.phase == .adopting || !adoptionEnabled)
            .accessibilityLabel(l10n.text(.aiCueUseForEvent))
            .accessibilityHint(
                adoptionEnabled ? l10n.text(.aiCueUseForEvent) : adoptionUnavailableHint
            )
            .accessibilityIdentifier(
                "event-settings.ai-cue.candidate.\(candidate.variant.rawValue).use")
        }
        .padding(10)
        .background(ClaudioTheme.panel(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .stroke(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "event-settings.ai-cue.candidate.\(candidate.variant.rawValue).row")
    }

    private var appliedStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(l10n.text(.aiCueAppliedTitle), systemImage: "checkmark.circle.fill")
                .font(ClaudioTheme.font(.sectionTitle).weight(.semibold))
                .foregroundColor(ClaudioTheme.success(colorScheme))
            if let outcome = viewModel.adoptionOutcome {
                Text(l10n.format(.aiCueAppliedMessage, outcome.finalDisplayName))
                    .font(ClaudioTheme.font(.body))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
            }
            Button(l10n.text(.commonClose), action: onClose)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(l10n.text(.commonClose))
                .accessibilityIdentifier("event-settings.ai-cue.applied-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.ai-cue.applied")
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ClaudioTheme.error(colorScheme))
                .accessibilityHidden(true)
            Text(message)
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudioTheme.error(colorScheme).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.ai-cue.error")
    }

    private func candidateDuration(_ candidate: AICueCandidate) -> String {
        let seconds = Double(candidate.durationMilliseconds) / 1_000
        let value = String(format: "%.1f", seconds)
        return l10n.format(.aiCueCandidateDuration, value)
    }

    private func candidatePreviewLabel(_ candidate: AICueCandidate) -> String {
        localizedAICueCandidatePreviewAccessibilityLabel(
            variant: candidate.variant,
            duration: candidateDuration(candidate),
            isPlaying: playingCandidateID == candidate.id,
            language: languageStore.language)
    }
}

@MainActor
package struct EventSettingsAICueCredentialSheet: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var languageStore: ClaudioPreferences

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) private var colorScheme
    @State private var keyInput = ""
    @State private var inputError: AICueCredentialInputError?
    @State private var confirmsDeletion = false

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    package init(
        viewModel: AICueGenerationViewModel,
        languageStore: ClaudioPreferences
    ) {
        self.viewModel = viewModel
        self.languageStore = languageStore
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(credentialTitle)
                .font(ClaudioTheme.font(.sectionTitle).weight(.bold))
                .foregroundColor(ClaudioTheme.text(colorScheme))

            Text(l10n.text(privacyDisclosureKey))
                .font(ClaudioTheme.font(.body))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text(.aiCueCredentialKeychain))
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.credentialActivity != .idle {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(l10n.text(aiCueCredentialActivityKey(viewModel.credentialActivity)))
                        .font(ClaudioTheme.font(.caption))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("event-settings.ai-cue.credential-activity")
            }

            Text(l10n.text(.aiCueCredentialKeyLabel))
                .font(ClaudioTheme.font(.body).weight(.semibold))
            SecureField(l10n.text(.aiCueCredentialKeyLabel), text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .accessibilityLabel(l10n.text(.aiCueCredentialKeyLabel))
                .accessibilityIdentifier("event-settings.ai-cue.credential-input")

            if let inputError {
                credentialErrorNotice(credentialInputErrorText(inputError, l10n: l10n))
            } else if let failure = viewModel.credentialFailure {
                credentialErrorNotice(aiCueCredentialFailureText(failure, l10n: l10n))
            }

            HStack(spacing: 10) {
                if case .stored(_, true) = viewModel.credentialStatus {
                    Button(l10n.text(.aiCueCredentialCancelReplacement)) {
                        Task {
                            await viewModel.cancelPendingCredentialReplacement()
                        }
                    }
                    .disabled(viewModel.credentialActivity != .idle)
                    .accessibilityLabel(l10n.text(.aiCueCredentialCancelReplacement))
                    .accessibilityIdentifier(
                        "event-settings.ai-cue.credential-cancel-replacement")
                }
                if case .stored = viewModel.credentialStatus {
                    Button(l10n.text(.aiCueCredentialDelete), role: .destructive) {
                        confirmsDeletion = true
                    }
                    .disabled(viewModel.credentialActivity != .idle)
                    .accessibilityLabel(l10n.text(.aiCueCredentialDelete))
                    .accessibilityIdentifier("event-settings.ai-cue.credential-delete")
                }
                Spacer()
                Button(l10n.text(.commonCancel)) {
                    keyInput = ""
                    presentationMode.wrappedValue.dismiss()
                }
                .accessibilityLabel(l10n.text(.commonCancel))
                .accessibilityIdentifier("event-settings.ai-cue.credential-cancel")

                Button(saveButtonTitle) {
                    submitCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyInput.isEmpty || viewModel.credentialActivity != .idle)
                .accessibilityLabel(saveButtonTitle)
                .accessibilityIdentifier("event-settings.ai-cue.credential-save")
            }
        }
        .padding(24)
        .frame(width: 520)
        .alert(
            l10n.text(.aiCueCredentialDeleteTitle),
            isPresented: $confirmsDeletion
        ) {
            Button(l10n.text(.commonCancel), role: .cancel) {}
            Button(l10n.text(.commonDeletePermanently), role: .destructive) {
                Task {
                    await viewModel.deleteCredential()
                    if viewModel.credentialStatus == .missing {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        } message: {
            Text(l10n.text(.aiCueCredentialDeleteMessage))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(credentialTitle)
        .accessibilityIdentifier("event-settings.ai-cue.credential-sheet")
    }

    private var credentialTitle: String {
        l10n.format(
            .aiCueCredentialTitle,
            l10n.text(viewModel.providerProfile.displayNameKey))
    }

    private var privacyDisclosureKey: ClaudioL10nKey {
        switch viewModel.providerProfile.id {
        case .elevenLabsGlobal: return .aiCueCredentialPrivacy
        case .miniMaxGlobal: return .aiCueCredentialPrivacyMiniMax
        case .qwenSingapore: return .aiCueCredentialPrivacyQwenSingapore
        case .qwenBeijing: return .aiCueCredentialPrivacyQwenBeijing
        default: preconditionFailure("Provider profile was not resolved through the registry")
        }
    }

    private var saveButtonTitle: String {
        switch viewModel.providerProfile.credentialValidationPolicy {
        case .readOnlyProbe: return l10n.text(.aiCueCredentialValidateSave)
        case .deferredUntilExplicitGeneration: return l10n.text(.aiCueCredentialSave)
        }
    }

    private func submitCredential() {
        let credential: SensitiveCredentialInput
        do {
            credential = try SensitiveCredentialInput(keyInput)
        } catch let error as AICueCredentialInputError {
            inputError = error
            return
        } catch {
            inputError = .empty
            return
        }
        inputError = nil
        keyInput = ""
        Task {
            await viewModel.saveCredential(credential)
            if viewModel.credentialFailure == nil,
                case .stored = viewModel.credentialStatus
            {
                presentationMode.wrappedValue.dismiss()
            }
        }
    }

    private func credentialErrorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ClaudioTheme.error(colorScheme))
                .accessibilityHidden(true)
            Text(message)
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.ai-cue.credential-error")
    }
}

private func credentialInputErrorText(
    _ error: AICueCredentialInputError,
    l10n: ClaudioL10n
) -> String {
    switch error {
    case .empty, .tooLong, .containsControlCharacters:
        return l10n.text(.aiCueErrorCredentialInvalid)
    }
}

private func aiCueCredentialActivityKey(
    _ activity: AICueCredentialActivity
) -> ClaudioL10nKey {
    switch activity {
    case .idle: return .aiCueServiceChecking
    case .probing: return .aiCueCredentialProbing
    case .saving: return .aiCueCredentialSaving
    case .pendingReplacement: return .aiCueCredentialUpdatingReplacement
    case .deleting: return .aiCueCredentialDeleting
    }
}

private func aiCueModalityKey(_ modality: AICueModality) -> ClaudioL10nKey {
    switch modality {
    case .speech: return .aiCueModalitySpeech
    case .animal: return .aiCueModalityAnimal
    case .soundEffect: return .aiCueModalitySoundEffect
    case .mixed: return .aiCueModalityMixed
    }
}

private func aiCueCredentialFailureText(
    _ failure: AICueCredentialFailure,
    l10n: ClaudioL10n
) -> String {
    switch failure {
    case .provider(.invalidCredential), .provider(.forbidden),
        .provider(.requiredModelsUnavailable):
        return l10n.text(.aiCueErrorCredentialInvalid)
    case .provider(.insufficientCredits):
        return l10n.text(.aiCueErrorCredits)
    case .provider(.rateLimited):
        return l10n.text(.aiCueErrorRateLimited)
    case .provider, .storageUnavailable:
        return l10n.text(.aiCueErrorCredentialUnavailable)
    }
}

private func aiCueFailureText(
    _ failure: AICueComposerFailure,
    l10n: ClaudioL10n
) -> String {
    switch failure {
    case .generation(.validation(.emptyDescription)):
        return l10n.text(.aiCueErrorDescriptionRequired)
    case .generation(.validation(.descriptionTooLong)):
        return l10n.text(.aiCueErrorDescriptionTooLong)
    case .generation(.validation(.spokenContentRequired)):
        return l10n.text(.aiCueErrorSpeechNeedsText)
    case .generation(.validation(.invalidLocale)),
        .generation(.requestCompilation(.unsupportedLocale)):
        return l10n.text(.aiCueErrorUnsupportedLocale)
    case .generation(.requestCompilation(.unsupportedModality)):
        return l10n.text(.aiCueErrorUnsupportedModality)
    case .generation(.requestCompilation(.spokenContentRequired)):
        return l10n.text(.aiCueErrorSpeechNeedsText)
    case .generation(.credentialRequired):
        return l10n.text(.aiCueErrorCredentialRequired)
    case .generation(.credentialUnavailable):
        return l10n.text(.aiCueErrorCredentialUnavailable)
    case .generation(.provider(.invalidCredential)),
        .generation(.provider(.forbidden)),
        .generation(.provider(.requiredModelsUnavailable)):
        return l10n.text(.aiCueErrorCredentialInvalid)
    case .generation(.provider(.insufficientCredits)):
        return l10n.text(.aiCueErrorCredits)
    case .generation(.provider(.rateLimited)):
        return l10n.text(.aiCueErrorRateLimited)
    case .generation(.audioTooLarge), .generation(.unsupportedAudio),
        .generation(.audioDurationUnavailable), .generation(.audioTooLong):
        return l10n.text(.aiCueErrorAudioInvalid)
    case .generation:
        return l10n.text(.aiCueErrorGeneration)
    case .displayName(.emptyDisplayName):
        return l10n.text(.aiCueErrorNameRequired)
    case .displayName:
        return l10n.text(.aiCueErrorNameInvalid)
    case .adoption(.importedButNotBound):
        return l10n.text(.aiCueErrorAdoptionPartial)
    case .adoption(.targetChanged):
        return l10n.text(.aiCueErrorAdoptionTarget)
    case .adoption:
        return l10n.text(.aiCueErrorAdoption)
    }
}
