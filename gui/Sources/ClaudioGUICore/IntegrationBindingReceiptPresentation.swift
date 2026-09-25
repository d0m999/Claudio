import ClaudioCore
import ClaudioLocalization

/// 只读逐绑定投影；能力覆盖与宿主 ready 不能代替这一绑定的回执。
public struct IntegrationBindingReceiptPresentation: Identifiable, Sendable, Equatable {
    public var id: HostEventBindingID { binding.id }
    public let binding: HostCapabilityBinding
    public let activation: HostActivationEvidence

    public init(binding: HostCapabilityBinding, snapshot: HostIntegrationSnapshot?) {
        self.binding = binding
        guard let snapshot, snapshot.configuration == .configured,
            let installationID = snapshot.installationID
        else {
            activation = .none
            return
        }
        if case .observed(let evidence)? = snapshot.bindingActivations[binding.id],
            evidence.bindingID == binding.id, evidence.installationID == installationID
        {
            activation = .observed(evidence)
        } else {
            activation = .awaitingReceipt(installationID: installationID)
        }
    }

    public func text(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let key: ClaudioL10nKey
        switch activation {
        case .none: key = .integrationsBindingNoReceipt
        case .awaitingReceipt: key = .integrationsBindingAwaitingReceipt
        case .observed: key = .integrationsBindingCurrentReceipt
        }
        return l10n.format(key, binding.nativeEvent ?? binding.event.rawValue)
    }
}
