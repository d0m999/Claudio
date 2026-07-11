import Combine
import Foundation

/// Drives the onboarding panel: holds the current ``OnboardingState`` (detected from
/// ``environment``), exposes its ``OnboardingCopy``, and re-detects on demand via
/// ``refresh()`` — the state machine's one and only transition rule (see
/// ``detectOnboardingState(environment:)``'s doc comment).
///
/// Deliberately **does not** call `installClaudioHooks`/`uninstallClaudioHooks` (or spawn
/// the `claudio` binary) itself. Wiring a CTA tap to an actual side-effecting action is
/// the menu bar shell's job (ENGINEERING.md T8/T15) — this view-model exposes
/// ``performPrimaryAction()``/``performSecondaryAction()`` as the seam that future work
/// hooks into via ``onPrimaryAction``/``onSecondaryAction``, defaulting to a no-op so T7
/// can ship the state machine + copy without prematurely committing to how that wiring
/// happens. Every test in this module exercises transitions directly through
/// ``refresh()`` against a fixture ``OnboardingEnvironment`` instead.
@MainActor
public final class OnboardingViewModel: ObservableObject {
    /// Where on disk this view-model looks — injectable so previews/tests never touch
    /// the real `~/.claude` / `~/.claudio` (see ``OnboardingEnvironment``'s warning about
    /// `$HOME` not working on Darwin).
    public var environment: OnboardingEnvironment

    @Published public private(set) var state: OnboardingState

    /// Invoked by ``performPrimaryAction()``, before ``refresh()`` re-detects state.
    /// `nil` (no-op) by default.
    public var onPrimaryAction: (@MainActor () -> Void)?

    /// Invoked by ``performSecondaryAction()``, before ``refresh()`` re-detects state.
    /// `nil` (no-op) by default.
    public var onSecondaryAction: (@MainActor () -> Void)?

    public init(environment: OnboardingEnvironment = OnboardingEnvironment()) {
        self.environment = environment
        self.state = detectOnboardingState(environment: environment)
    }

    #if DEBUG
        /// Preview-only initializer (ENGINEERING.md T14 D2): pins ``state`` directly to
        /// `previewState`, without running ``detectOnboardingState(environment:)`` or
        /// touching disk at all — the state gallery's only way to render a SPECIFIC
        /// ``OnboardingState`` deterministically (a real `refresh()` would re-detect from
        /// `environment` and overwrite whatever this pinned). `environment` is still set to
        /// a harmless, never-resolved placeholder (not the real `~/.claude`/`~/.claudio`
        /// paths — see ``OnboardingEnvironment``'s own warning about `$HOME`), purely so the
        /// stored property has a value; nothing in the gallery ever calls ``refresh()`` on a
        /// preview-pinned instance. `#if DEBUG`-gated so this never ships in release and
        /// can't be misused in production; must live in THIS file (not a separate
        /// extension) since ``state``'s setter is `private`, and Swift's `private` is
        /// file-scoped, not module-scoped.
        public init(previewState: OnboardingState) {
            self.environment = OnboardingEnvironment(
                settingsFile: URL(fileURLWithPath: "/dev/null/claudio-preview-settings.json"),
                claudioBinaryPath: URL(fileURLWithPath: "/dev/null/claudio-preview-binary"))
            self.state = previewState
        }
    #endif

    /// This state's presentation copy — recomputed from ``state``, never cached, so it
    /// can never drift out of sync with it.
    public var copy: OnboardingCopy {
        onboardingCopy(for: state)
    }

    /// Re-runs detection against the current ``environment`` and updates ``state``. The
    /// state machine's entire transition rule: call this after anything that might have
    /// changed the on-disk facts (a fix applied outside the app, the panel regaining
    /// focus, an action completing).
    public func refresh() {
        state = detectOnboardingState(environment: environment)
    }

    /// Runs the state's primary CTA action (if any is wired), then refreshes.
    public func performPrimaryAction() {
        onPrimaryAction?()
        refresh()
    }

    /// Runs the state's secondary CTA action (if any is wired), then refreshes.
    public func performSecondaryAction() {
        onSecondaryAction?()
        refresh()
    }
}
