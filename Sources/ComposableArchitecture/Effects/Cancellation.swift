import Foundation
import RxSwift

class AnyDisposable: Disposable, Hashable {
  let _dispose: () -> Void

  init(_ disposable: Disposable) {
    _dispose = disposable.dispose
  }

  func dispose() {
    _dispose()
  }

  static func == (lhs: AnyDisposable, rhs: AnyDisposable) -> Bool {
    return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

extension Effect {
  /// Turns an effect into one that is capable of being canceled.
  ///
  /// To turn an effect into a cancellable one you must provide an identifier, which is used in
  /// `Effect.cancel(id:)` to identify which in-flight effect should be canceled. Any hashable
  /// value can be used for the identifier, such as a string, but you can add a bit of protection
  /// against typos by defining a new type that conforms to `Hashable`, such as an empty struct:
  ///
  ///     struct LoadUserId: Hashable {}
  ///
  ///     case .reloadButtonTapped:
  ///       // Start a new effect to load the user
  ///       return environment.loadUser
  ///         .map(Action.userResponse)
  ///         .cancellable(id: LoadUserId(), cancelInFlight: true)
  ///
  ///     case .cancelButtonTapped:
  ///       // Cancel any in-flight requests to load the user
  ///       return .cancel(id: LoadUserId())
  ///
  /// - Parameters:
  ///   - id: The effect's identifier.
  ///   - cancelInFlight: Determines if any in-flight effect with the same identifier should be
  ///     canceled before starting this new one.
  /// - Returns: A new effect that is capable of being canceled by an identifier.
  public func cancellable(id: AnyHashable, cancelInFlight: Bool = false) -> Effect {
    let effect = Observable<Output>.deferred {
      cancellablesLock.lock()
      defer { cancellablesLock.unlock() }

      let id = CancelToken(id: id)
      if cancelInFlight {
        cancellationCancellables[id]?.forEach { $0.dispose() }
      }

      let cancellationSubject = PublishSubject<Void>()

      var cancellationDisposable: AnyDisposable!
      cancellationDisposable = AnyDisposable(
        Disposables.create {
          cancellablesLock.sync {
            cancellationSubject.onNext(())
            cancellationSubject.onCompleted()
            cancellationCancellables[id]?.remove(cancellationDisposable)
            if cancellationCancellables[id]?.isEmpty == .some(true) {
              cancellationCancellables[id] = nil
            }
          }
        }
      )

      return self.take(until: cancellationSubject)
        .do(
          afterError: { _ in cancellationDisposable.dispose() },
          afterCompleted: cancellationDisposable.dispose,
          onSubscribed: {
            _ = cancellablesLock.sync {
              cancellationCancellables[id, default: []].insert(
                cancellationDisposable
              )
            }
          },
          onDispose: cancellationDisposable.dispose
        )
    }
    .eraseToEffect()

    return effect
  }

  /// An effect that will cancel any currently in-flight effect with the given identifier.
  ///
  /// - Parameter id: An effect identifier.
  /// - Returns: A new effect that will cancel any currently in-flight effect with the given
  ///   identifier.
  public static func cancel(id: AnyHashable) -> Effect {
    return .fireAndForget {
      cancellablesLock.sync {
        cancellationCancellables[.init(id: id)]?.forEach { $0.dispose() }
      }
    }
  }
}

struct CancelToken: Hashable {
  let id: AnyHashable
  let discriminator: ObjectIdentifier

  init(id: AnyHashable) {
    self.id = id
    self.discriminator = ObjectIdentifier(type(of: id.base))
  }
}

var cancellationCancellables: [CancelToken: Set<AnyDisposable>] = [:]
let cancellablesLock = NSRecursiveLock()
