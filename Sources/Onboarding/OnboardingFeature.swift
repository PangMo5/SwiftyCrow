// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Sharing

@Reducer
struct OnboardingFeature {

  // MARK: Internal

  enum Step: Int, CaseIterable, Identifiable {
    // Keep persisted values stable when inserting a new setup step.
    case welcome = 0
    case prepare = 1
    case ready = 2
    case shortcuts = 3

    static let allCases: [Self] = [.welcome, .prepare, .shortcuts, .ready]

    var position: Int {
      Self.allCases.firstIndex(of: self)!
    }

    var id: Int {
      rawValue
    }
  }

  struct ModelCheck: Equatable, Sendable {
    let id: Int
    let source: Language
    let target: Language
    let strategy: TranslationStrategy
  }

  @ObservableState
  struct State: Equatable {
    @Shared(.appStorage("onboardingStarted")) var hasStarted = false
    @Shared(.appStorage("onboardingCompleted")) var completed = false
    @Shared(.appStorage("onboardingStep")) var savedStep = 0
    @Shared(.appStorage("onboardingDraftTarget")) var savedTarget = ""
    @Shared(.appStorage("onboardingResumeRequested")) var resumeRequested = false
    @Shared(.appStorage("onboardingCheckSource")) var savedCheckSource = Language.defaultSource.code
    @Shared(.settings) var settings
    var isPresented = false
    var hasCheckedLaunch = false
    var step = Step.welcome
    var hasScreenRecording = false
    var isRequestingAccess = false
    var requestedAccess = false
    var isRelaunching = false
    var relaunchError: String?
    var targetLanguages = [Language]()
    var target = Language.systemPreferred()
    var startCaptureAfterDismissal = false
    var modelReadiness = LanguageReadiness.unchecked
    var modelCheck: ModelCheck?
    var modelCheckID = 0

    var modelSource: Language {
      Language(code: savedCheckSource)
    }
  }

  enum Action {
    case launchChecked(hasExistingConfiguration: Bool)
    case openRequested
    case appeared
    case closed
    case becameActive
    case accessLoaded(Bool)
    case grantAccessTapped
    case accessRequestFinished(Bool)
    case openAccessSettingsTapped
    case relaunchTapped
    case relaunchFailed(String)
    case languagesLoaded([Language])
    case targetChanged(Language)
    case modelSourceChanged(Language)
    case checkModelsTapped
    case modelReadinessLoaded(ModelCheck, LanguageReadiness)
    case nextTapped
    case backTapped
    case skipTapped
    case finishTapped(startCapture: Bool)
  }

  enum CancelID { case access, languages, changes, models }

  @Dependency(\.screenRecordingAccess) var access
  @Dependency(\.languageCatalog) var languages
  @Dependency(\.appRelaunch) var relaunch

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .launchChecked(let hasExistingConfiguration):
        guard !state.hasCheckedLaunch else { return .none }
        state.hasCheckedLaunch = true
        let resuming = state.resumeRequested
        guard !state.completed || resuming else { return .none }
        if hasExistingConfiguration, !state.hasStarted, !resuming {
          state.$completed.withLock { $0 = true }
          return .none
        }
        Self.present(&state, resuming: resuming)
        state.$resumeRequested.withLock { $0 = false }
        return .none

      case .openRequested:
        guard !state.isPresented else { return .none }
        Self.present(&state)
        return .none

      case .appeared:
        return .merge(
          .send(.becameActive),
          .run { [access] send in
            for await _ in access.changes() { await send(.becameActive) }
          }
          .cancellable(id: CancelID.changes, cancelInFlight: true),
          .run { [languages] send in await send(.languagesLoaded(languages.supported(false))) }
            .cancellable(id: CancelID.languages, cancelInFlight: true)
        )

      case .becameActive:
        guard state.isPresented else { return .none }
        return .run { [access] send in await send(.accessLoaded(access.isGranted())) }
          .cancellable(id: CancelID.access, cancelInFlight: true)

      case .accessLoaded(let granted):
        guard state.isPresented else { return .none }
        state.hasScreenRecording = granted
        return .none

      case .grantAccessTapped:
        guard !state.isRequestingAccess else { return .none }
        state.isRequestingAccess = true
        state.requestedAccess = true
        Self.prepareForExternalFlow(&state)
        return .run { [access, relaunch] send in
          await relaunch.prepare()
          _ = await access.request()
          await access.openSettings()
          await send(.accessRequestFinished(access.isGranted()))
        }

      case .accessRequestFinished(let granted):
        state.isRequestingAccess = false
        guard state.isPresented else { return .none }
        state.hasScreenRecording = granted
        return .none

      case .openAccessSettingsTapped:
        Self.prepareForExternalFlow(&state)
        return .run { [access, relaunch] _ in
          await relaunch.prepare()
          await access.openSettings()
        }

      case .relaunchTapped:
        guard !state.isRelaunching else { return .none }
        Self.prepareForExternalFlow(&state)
        state.isRelaunching = true
        state.relaunchError = nil
        return .run { [relaunch] send in
          await relaunch.prepare()
          do { try await relaunch.relaunch() }
          catch { await send(.relaunchFailed(error.localizedDescription)) }
        }

      case .relaunchFailed(let message):
        state.isRelaunching = false
        state.relaunchError = message
        return .none

      case .languagesLoaded(let values):
        guard state.isPresented else { return .none }
        state.targetLanguages = values
        return .none

      case .targetChanged(let target):
        state.target = target
        state.$savedTarget.withLock { $0 = target.code }
        state.modelCheck = nil
        state.modelReadiness = .unchecked
        return .cancel(id: CancelID.models)

      case .modelSourceChanged(let source):
        state.$savedCheckSource.withLock { $0 = source.code }
        state.modelCheck = nil
        state.modelReadiness = .unchecked
        return .cancel(id: CancelID.models)

      case .checkModelsTapped:
        guard state.isPresented else { return .none }
        state.modelCheckID += 1
        let request = ModelCheck(
          id: state.modelCheckID,
          source: state.modelSource,
          target: state.target,
          strategy: state.settings.translation.strategy
        )
        state.modelCheck = request
        state.modelReadiness = .checking
        return .run { [languages] send in
          let result = await languages.readiness(request.source, request.target, request.strategy)
          try Task.checkCancellation()
          await send(.modelReadinessLoaded(request, result))
        }
        .cancellable(id: CancelID.models, cancelInFlight: true)

      case .modelReadinessLoaded(let request, let result):
        guard
          state.isPresented, state.modelCheck == request,
          state.modelSource == request.source, state.target == request.target,
          state.settings.translation.strategy == request.strategy
        else { return .none }
        state.modelReadiness = result
        return .none

      case .nextTapped:
        guard state.step.position + 1 < Step.allCases.count else { return .none }
        let step = Step.allCases[state.step.position + 1]
        state.step = step
        state.$savedStep.withLock { $0 = step.rawValue }
        return .none

      case .backTapped:
        guard state.step.position > 0 else { return .none }
        let step = Step.allCases[state.step.position - 1]
        state.step = step
        state.$savedStep.withLock { $0 = step.rawValue }
        return .none

      case .skipTapped:
        state.$completed.withLock { $0 = true }
        state.$resumeRequested.withLock { $0 = false }
        state.$savedTarget.withLock { $0 = "" }
        state.isPresented = false
        return .none

      case .finishTapped(let startCapture):
        guard !startCapture || state.hasScreenRecording else { return .none }
        state.$settings.withLock { $0.languages.target = state.target }
        state.$completed.withLock { $0 = true }
        state.$savedStep.withLock { $0 = 0 }
        state.$resumeRequested.withLock { $0 = false }
        state.$savedTarget.withLock { $0 = "" }
        state.startCaptureAfterDismissal = startCapture
        state.isPresented = false
        return .none

      case .closed:
        state.isPresented = false
        return .merge(
          .cancel(id: CancelID.access),
          .cancel(id: CancelID.languages),
          .cancel(id: CancelID.changes),
          .cancel(id: CancelID.models)
        )
      }
    }
  }

  static func prepareForExternalFlow(_ state: inout State) {
    state.$savedTarget.withLock { $0 = state.target.code }
    state.$savedStep.withLock { $0 = state.step.rawValue }
    state.$resumeRequested.withLock { $0 = true }
  }

  // MARK: Private

  private static func present(_ state: inout State, resuming: Bool = false) {
    state.$hasStarted.withLock { $0 = true }
    let restore = resuming || !state.completed
    state.target = restore && !state.savedTarget.isEmpty ? Language(code: state.savedTarget) : state.settings.languages.target
    state.step = restore ? (Step(rawValue: state.savedStep) ?? .welcome) : .welcome
    state.modelReadiness = .unchecked
    state.modelCheck = nil
    state.relaunchError = nil
    state.isRelaunching = false
    state.startCaptureAfterDismissal = false
    state.isPresented = true
  }

}
