//
//  Promise.swift
//  ReactiveCocoa
//
//  Created by Justin Spahr-Summers on 2014-06-29.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

import Foundation

private enum PromiseState<T> {
	case Suspended(SinkOf<T> -> ())
	case Started
}

/// Represents deferred work to generate a value of type T.
public final class Promise<T> {
	private let state: Atomic<PromiseState<T>>
	private let sink: SinkOf<T?>

	/// A signal of the Promise's value. This will be `nil` before the promise
	/// has been resolved, and the generated value afterward.
	public let signal: Signal<T?>

	/// Initializes a Promise that will run the given action when started.
	///
	/// The action must eventually `put` a value into the given sink to resolve
	/// the Promise.
	public init(action: SinkOf<T> -> ()) {
		state = Atomic(.Suspended(action))
		(signal, sink) = Signal.pipeWithInitialValue(nil)
	}

	/// Starts the promise, if it hasn't started already.
	public func start() {
		let oldState = state.modify { _ in .Started }

		switch oldState {
		case let .Suspended(action):
			// Hold on to the `action` closure until the promise is resolved.
			let disposable = ActionDisposable { [action] in }

			let disposableSink = SinkOf<T> { [weak self] value in
				if disposable.disposed {
					return
				}

				disposable.dispose()
				self?.sink.put(value)
			}

			action(disposableSink)

		default:
			break
		}
	}

	/// Starts the promise (if necessary), then blocks indefinitely on the
	/// result.
	public func await() -> T {
		let cond = NSCondition()
		cond.name = "com.github.ReactiveCocoa.Promise.await"

		let disposable = signal.observe { _ in
			cond.lock()
			cond.signal()
			cond.unlock()
		}

		start()

		cond.lock()
		while signal.current == nil {
			cond.wait()
		}

		let result = signal.current!
		cond.unlock()

		disposable.dispose()
		return result
	}

	/// Performs the given action when the promise completes.
	///
	/// This method does not start the promise or block waiting for it.
	///
	/// Returns a Disposable that can be used to cancel the given action before
	/// it occurs.
	public func notify(action: T -> ()) -> Disposable {
		let disposable = SerialDisposable()

		disposable.innerDisposable = signal.observe { value in
			if let value = value {
				disposable.dispose()
				action(value)
			}
		}

		return disposable
	}

	/// Creates a Promise that will start the receiver, then run the given
	/// action and forward the results.
	public func then<U>(action: T -> Promise<U>) -> Promise<U> {
		return Promise<U> { sink in
			let disposable = SerialDisposable()

			disposable.innerDisposable = self.notify { result in
				let innerPromise = action(result)
				disposable.innerDisposable = innerPromise.notify { result in
					sink.put(result)
				}

				innerPromise.start()
			}

			self.start()
		}
	}
}
