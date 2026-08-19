import ClaudioCore
import Foundation

@MainActor
public final class BootstrapReportPresentationStore: ObservableObject {
    @Published private(set) var records: [BootstrapReportRecord] = []
    @Published private(set) var acknowledgementError: String?

    private let store: BootstrapReportStore
    private var announcedRevisions: Set<String> = []

    init(store: BootstrapReportStore = BootstrapReportStore()) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            records = try store.records()
        } catch {
            acknowledgementError = String(describing: error)
        }
    }

    func acknowledge(_ id: UUID) {
        do {
            try store.acknowledge(id)
            records.removeAll { $0.id == id }
            acknowledgementError = nil
        } catch {
            acknowledgementError = String(describing: error)
        }
    }

    func pendingAnnouncementRecords() -> [BootstrapReportRecord] {
        records.filter { !announcedRevisions.contains(announcementRevision(for: $0)) }
    }

    func markAnnounced(_ records: [BootstrapReportRecord]) {
        announcedRevisions.formUnion(records.map(announcementRevision(for:)))
    }

    private func announcementRevision(for record: BootstrapReportRecord) -> String {
        "\(record.id.uuidString):\(record.occurrenceCount)"
    }
}
