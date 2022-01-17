//
//  ViewModel.swift
//  Reduxift
//
//  Created by YEONGJUNG KIM on 2022/01/14.
//

import Foundation
import RxSwift
import RxRelay
import RxCocoa

/// Redux like ViewModel class.
///
/// Bind actions with `action` property and bind `state`, `event` properties to get data and evnets.
/// Way to use `state` property is depend on State protocol you conforming.
public class ViewModel<Action: ViewModelAction,
                       Mutation: ViewModelMutation,
                       State: ViewModelState,
                       Event: ViewModelEvent>
{
    typealias Action = Action
    typealias Mutation = Mutation
    typealias State = State
    typealias Event = Event
        
    typealias ActionMiddleware = Middleware<Action>
    typealias MutationMiddleware = Middleware<Mutation>
    typealias EventMiddleware = Middleware<Event>
        
    typealias GetState = () -> State
    typealias Dispatch<What> = (What) -> What
    typealias Middleware<What> = (@escaping GetState) -> MiddlewareTranducer<What>
    typealias MiddlewareTranducer<What> = (@escaping Dispatch<What>) -> Dispatch<What>
    
    typealias StateMiddleware = StateMiddlewareTranducer//() -> StateMiddlewareTranducer
    typealias StateMiddlewareTranducer = (@escaping Dispatch<State>) -> Dispatch<State>
        
    /// Reaction is side-effect of Action
    enum Reaction {
        case mutation(Mutation)
        case event(Event)
        
        var mutation: Mutation? {
            guard case let .mutation(mutation) = self else { return nil }
            return mutation
        }
        var event: Event? {
            guard case let .event(event) = self else { return nil }
            return event
        }
    }
    
    /// Middleware helper type
    struct MiddlewareGenerator {
        func action(_ process: @escaping (_ state: GetState, _ next: Dispatch<Action>, _ action: Action) -> Action) -> Middleware<Action> {
            nontyped_middleware(process)
        }
        func mutation(_ process: @escaping (_ state: GetState, _ next: Dispatch<Mutation>, _ mutation: Mutation) -> Mutation) -> Middleware<Mutation> {
            nontyped_middleware(process)
        }
        func event(_ process: @escaping (_ state: GetState, _ next: Dispatch<Event>, _ event: Event) -> Event) -> Middleware<Event> {
            nontyped_middleware(process)
        }
        func state(_ process: @escaping (_ state: State, _ next: Dispatch<State>) -> State) -> StateMiddleware {
            nontyped_state_middleware(process)
        }
    }
    
    // MARK: - Interfaces

    /// Middleware generator
    static var middleware: MiddlewareGenerator { MiddlewareGenerator() }
    
    // Action
    var action: Binder<Action> {
        Binder<Action>(self) { base, action in
            base.userActionRelay.accept(action)
        }
    }
    
    // Event output
    var event: Signal<Event> { eventRelay.asSignal() }
    
    // State output
    var state: StateDriver<State> { StateDriver(stateRelay) }

    // MARK: - Private properties
    
    private(set) var db = DisposeBag()
    
    fileprivate let userActionRelay = PublishRelay<Action>()

    fileprivate let actionRelay = PublishRelay<Action>()
    fileprivate let reactionRelay = PublishRelay<Reaction>()
    fileprivate let mutationRelay = PublishRelay<Mutation>()
    fileprivate let eventRelay = PublishRelay<Event>()
    fileprivate let stateRelay: BehaviorRelay<State>
    
    deinit {
        print("deinit: \(self)")
    }
    
    // MARK: - Intialize
        
    /// Initializes a view model with state and middlewares
    /// - Parameters:
    ///   - initialState: initial state
    ///   - actionMiddlewares: action middlewares
    ///   - mutationMiddlewares: mutation middlewares
    ///   - eventMiddlewares: event middlewares
    init(state initialState: State,
         actionMiddlewares: [ActionMiddleware] = [],
         mutationMiddlewares: [MutationMiddleware] = [],
         eventMiddlewares: [EventMiddleware] = [],
         stateMiddlewares: [StateMiddleware] = [])
    {
        // state
        stateRelay = BehaviorRelay<State>(value: initialState)
        
        let dispatchAction = Self.dispatcher(actionMiddlewares, actionRelay, stateRelay)
        let dispatchMutation = Self.dispatcher(mutationMiddlewares, mutationRelay, stateRelay)
        let dispatchEvent = Self.dispatcher(eventMiddlewares, eventRelay, stateRelay)
        let statePostMiddleware = Self.statePostMiddleware(stateMiddlewares)
        
        // middleware(raw action) -> action
        userActionRelay
            .debug("[ViewModel] user action")
            .subscribe(onNext: {
                _ = dispatchAction($0)
            })
            .disposed(by: db)

        // react(action) -> reaction
        actionRelay
            .debug("[ViewModel] action 1")
            .withLatestFrom(stateRelay) { ($0, $1) }
            .flatMap { [weak self] (action, state) -> Observable<Reaction> in
                guard let self = self else { return .empty() }
                return self.react(action: action, state: state)
            }
            .debug("[ViewModel] action 2")
            .bind(to: reactionRelay)
            .disposed(by: db)
        
        // middleware(reaction.muation) -> mutation
        reactionRelay
            .compactMap { $0.mutation }
            .debug("[ViewModel] mutation")
            .subscribe(onNext: {
                _ = dispatchMutation($0)
            })
            .disposed(by: db)

        // middleware(reaction.event) -> event
        reactionRelay
            .compactMap { $0.event }
            .debug("[ViewModel] event")
            .subscribe(onNext: {
                _ = dispatchEvent($0)
            })
            .disposed(by: db)
        
        // reduce(mutation) -> state
        mutationRelay
            .scan(initialState) { [weak self] state, mutation in
                guard let self = self else { return state }
                return self.reduce(mutation: mutation, state: state)
            }
            .flatMap { statePostMiddleware($0) }
            .debug("[ViewModel] state")
            .bind(to: stateRelay)
            .disposed(by: db)
    }
    
    // MARK: - Interfaces

    /// Action react method.
    /// You should override this method to map an action to an observable of reactions.
    /// You can do asynchronous jobs in here and return `.mutations` to mutate the state, or `.event` to signal some event like an error to a user
    /// - Parameters:
    ///   - action: action to react
    ///   - state: current state
    /// - Returns: an observable of reactions
    func react(action: Action, state: State) -> Observable<Reaction> {
        fatalError("Override this method to use ViewModel")
    }
    
    /// State reducer method.
    /// You should override this method to configure the state with mutation.
    /// - Parameters:
    ///   - mutation: a mutation
    ///   - state: current state
    /// - Returns: new state
    func reduce(mutation: Mutation, state: State) -> State {
        state
    }
    
    // MARK: - Private methods
    
    /// Makes dispatch function of Action/Mutation/Event with middlewares
    /// - Parameter middlewares: middlewares
    /// - Parameter dispatchRelay: A relay to dispatch a action/mutation/event passed all middlewares
    /// - Parameter stateRelay: A relay to get a state
    /// - Returns: A dispatch function
    private static func dispatcher<T>(_ middlewares: [Middleware<T>],
                                      _ dispatchRelay: PublishRelay<T>,
                                      _ stateRelay: BehaviorRelay<State>) -> Dispatch<T> {
        { middlewares, dispatchRelay, stateRelay in
            let rawDispatch: Dispatch<T> = { dispatchRelay.accept($0); return $0 }
            let getState: GetState = { stateRelay.value }
            
            return middlewares.reversed().reduce(rawDispatch) { dispatch, mw in
                return mw(getState)(dispatch)
            }
        }(middlewares, dispatchRelay, stateRelay)
    }
        
    /// Makes post-middleware stack for state.
    /// - Parameter middlewares: state middlewares
    /// - Returns: A state middleware stack function
    private static func statePostMiddleware(_ middlewares: [StateMiddleware]) -> (State) -> Observable<State> {
        let rawState: Dispatch<State> = { $0 }
        
        let f: Dispatch<State> = middlewares.reversed().reduce(rawState) { mwStack, mw in
            return mw(mwStack)
        }
                
        return { .just(f($0)) }
    }
}