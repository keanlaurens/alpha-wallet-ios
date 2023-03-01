//
//  WalletConnectCoordinator.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 02.07.2020.
//

import UIKit
import AlphaWalletGoBack
import WalletConnectSwift
import PromiseKit
import Combine
import AlphaWalletFoundation
import AlphaWalletLogger
import AlphaWalletCore

protocol WalletConnectCoordinatorDelegate: CanOpenURL, SendTransactionAndFiatOnRampDelegate, DappRequesterDelegate {
    func universalScannerSelected(in coordinator: WalletConnectCoordinator)
}

class WalletConnectCoordinator: NSObject, Coordinator {

    private let navigationController: UINavigationController
    private let keystore: Keystore
    private let analytics: AnalyticsLogger
    private let domainResolutionService: DomainResolutionServiceType
    private let config: Config
    private weak var connectionTimeoutViewController: WalletConnectConnectionTimeoutViewController?
    private weak var notificationAlertController: UIViewController?
    private weak var sessionsViewController: WalletConnectSessionsViewController?
    private let assetDefinitionStore: AssetDefinitionStore
    private let networkService: NetworkService
    private let dependencies: AtomicDictionary<Wallet, AppCoordinator.WalletDependencies>

    let walletConnectProvider: WalletConnectProvider

    weak var delegate: WalletConnectCoordinatorDelegate?
    var coordinators: [Coordinator] = []

    init(keystore: Keystore,
         navigationController: UINavigationController,
         analytics: AnalyticsLogger,
         domainResolutionService: DomainResolutionServiceType,
         config: Config,
         assetDefinitionStore: AssetDefinitionStore,
         networkService: NetworkService,
         walletConnectProvider: WalletConnectProvider,
         dependencies: AtomicDictionary<Wallet, AppCoordinator.WalletDependencies>) {

        self.dependencies = dependencies
        self.walletConnectProvider = walletConnectProvider
        self.networkService = networkService
        self.config = config
        self.keystore = keystore
        self.navigationController = navigationController
        self.analytics = analytics
        self.domainResolutionService = domainResolutionService
        self.assetDefinitionStore = assetDefinitionStore

        super.init()
        walletConnectProvider.delegate = self
    }

    func openSession(url: AlphaWallet.WalletConnect.ConnectionUrl) {
        if sessionsViewController == nil {
            navigationController.setNavigationBarHidden(false, animated: true)
        }

        showSessions(state: .waitingForSessionConnection, navigationController: navigationController) {
            do {
                try self.walletConnectProvider.connect(url: url)
            } catch {
                let errorMessage = R.string.localizable.walletConnectFailureTitle()
                self.displayErrorMessage(errorMessage)
            }
        }
    }

    func showSessionDetails(in navigationController: UINavigationController) {
        if walletConnectProvider.sessions.count == 1 {
            display(session: walletConnectProvider.sessions[0], in: navigationController)
        } else {
            showSessions(state: .sessions, navigationController: navigationController)
        }
    }

    func showSessions() {
        navigationController.setNavigationBarHidden(false, animated: false)
        showSessions(state: .sessions, navigationController: navigationController)

        if walletConnectProvider.sessions.isEmpty {
            startUniversalScanner()
        }
    }

    private func showSessions(state: WalletConnectSessionsViewModel.State, navigationController: UINavigationController, completion: @escaping () -> Void = {}) {
        if let viewController = sessionsViewController {
            viewController.viewModel.set(state: state)
            completion()
        } else {
            let viewController = WalletConnectSessionsViewController(viewModel: .init(walletConnectProvider: walletConnectProvider, state: state))
            viewController.delegate = self
            viewController.navigationItem.rightBarButtonItem = UIBarButtonItem.qrCodeBarButton(self, selector: #selector(qrCodeButtonSelected))
            viewController.navigationItem.largeTitleDisplayMode = .never
            viewController.hidesBottomBarWhenPushed = true

            sessionsViewController = viewController

            navigationController.pushViewController(viewController, animated: true, completion: completion)
        }
    }

    @objc private func qrCodeButtonSelected(_ sender: UIBarButtonItem) {
        startUniversalScanner()
    }

    private func display(session: AlphaWallet.WalletConnect.Session, in navigationController: UINavigationController) {
        let coordinator = WalletConnectSessionCoordinator(
            analytics: analytics,
            navigationController: navigationController,
            walletConnectProvider: walletConnectProvider,
            session: session)

        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
    }

    private func displayConnectionTimeout(_ errorMessage: String) {
        func displayConnectionTimeoutViewPopup(message: String) {
            let pair = WalletConnectConnectionTimeoutViewController.promise(presentationViewController, errorMessage: errorMessage)
            notificationAlertController = pair.viewController

            pair.promise.done({ response in
                switch response {
                case .action:
                    self.delegate?.universalScannerSelected(in: self)
                case .canceled:
                    break
                }
            }).cauterize()
        }

        if let viewController = connectionTimeoutViewController {
            viewController.dismissAnimated(completion: {
                displayConnectionTimeoutViewPopup(message: errorMessage)
            })
        } else {
            displayConnectionTimeoutViewPopup(message: errorMessage)
        }

        resetSessionsToRemoveLoadingIfNeeded()
    }

    private func displayErrorMessage(_ errorMessage: String) {
        if let presentedController = notificationAlertController {
            presentedController.dismiss(animated: true) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.notificationAlertController = strongSelf.presentationViewController.displaySuccess(message: errorMessage)
            }
        } else {
            notificationAlertController = presentationViewController.displaySuccess(message: errorMessage)
        }
        resetSessionsToRemoveLoadingIfNeeded()
    }
}

extension WalletConnectCoordinator: WalletConnectSessionCoordinatorDelegate {
    func didClose(in coordinator: WalletConnectSessionCoordinator) {
        removeCoordinator(coordinator)
    }
}

extension WalletConnectCoordinator: WalletConnectProviderDelegate {

    func requestEthCall(from: AlphaWallet.Address?,
                        to: AlphaWallet.Address?,
                        value: String?,
                        data: String,
                        source: Analytics.SignMessageRequestSource,
                        session: WalletSession) -> AnyPublisher<String, PromiseError> {

        guard let delegate = delegate else { return .empty() }

        return delegate.requestEthCall(
            from: from,
            to: to,
            value: value,
            data: data,
            source: source,
            session: session)
    }

    func requestGetTransactionCount(session: WalletSession,
                                    source: Analytics.SignMessageRequestSource) -> AnyPublisher<Data, PromiseError> {

        guard let delegate = delegate else { return .empty() }
        
        return delegate.requestGetTransactionCount(
            session: session,
            source: source)
    }

    func requestSignMessage(message: SignMessageType,
                            server: RPCServer,
                            account: AlphaWallet.Address,
                            source: Analytics.SignMessageRequestSource,
                            requester: RequesterViewModel?) -> AnyPublisher<Data, PromiseError> {

        guard let delegate = delegate else { return .empty() }
        
        return delegate.requestSignMessage(
            message: message,
            server: server,
            account: account,
            source: source,
            requester: requester)
    }

    func requestSendRawTransaction(session: WalletSession,
                                   source: Analytics.TransactionConfirmationSource,
                                   requester: DappRequesterViewModel?,
                                   transaction: String) -> AnyPublisher<String, PromiseError> {

        guard let delegate = delegate else { return .empty() }

        return delegate.requestSendRawTransaction(
            session: session,
            source: source,
            requester: requester,
            transaction: transaction)
    }

    func requestSendTransaction(session: WalletSession,
                                source: Analytics.TransactionConfirmationSource,
                                requester: RequesterViewModel?,
                                transaction: UnconfirmedTransaction,
                                configuration: TransactionType.Configuration) -> AnyPublisher<SentTransaction, PromiseError> {

        guard let delegate = delegate else { return .empty() }
        
        return delegate.requestSendTransaction(
            session: session,
            source: source,
            requester: requester,
            transaction: transaction,
            configuration: configuration)
    }

    func requestSingTransaction(session: WalletSession,
                                source: Analytics.TransactionConfirmationSource,
                                requester: RequesterViewModel?,
                                transaction: UnconfirmedTransaction,
                                configuration: TransactionType.Configuration) -> AnyPublisher<Data, PromiseError> {

        guard let delegate = delegate else { return .empty() }

        return delegate.requestSingTransaction(
            session: session,
            source: source,
            requester: requester,
            transaction: transaction,
            configuration: configuration)
    }

    func requestAddCustomChain(server: RPCServer,
                               customChain: WalletAddEthereumChainObject) -> AnyPublisher<SwitchCustomChainOperation, PromiseError> {

        guard let delegate = delegate else { return .empty() }

        return delegate.requestAddCustomChain(server: server, customChain: customChain)
    }

    func requestSwitchChain(server: RPCServer,
                            currentUrl: URL?,
                            targetChain: WalletSwitchEthereumChainObject) -> AnyPublisher<SwitchExistingChainOperation, PromiseError> {

        guard let delegate = delegate else { return .empty() }

        return delegate.requestSwitchChain(server: server, currentUrl: nil, targetChain: targetChain)
    }

    private func resetSessionsToRemoveLoadingIfNeeded() {
        if let viewController = sessionsViewController {
            viewController.viewModel.set(state: .sessions)
        }
    }

    func provider(_ provider: WalletConnectProvider, didConnect walletConnectSession: AlphaWallet.WalletConnect.Session) {
        infoLog("[WalletConnect] didConnect session: \(walletConnectSession.topicOrUrl)")
        resetSessionsToRemoveLoadingIfNeeded()
    }

    private var presentationViewController: UIViewController {
        guard let keyWindow = UIApplication.shared.firstKeyWindow else { return navigationController }

        if let controller = keyWindow.rootViewController?.presentedViewController {
            return controller
        } else {
            return navigationController
        }
    }

    func provider(_ provider: WalletConnectProvider, didFail error: WalletConnectError) {
        infoLog("[WalletConnect] didFail error: \(error)")

        guard let description = error.localizedDescription else { return }
        displayErrorMessage(description)
    }

    func provider(_ provider: WalletConnectProvider, tookTooLongToConnectToUrl url: AlphaWallet.WalletConnect.ConnectionUrl) {
        if Features.default.isAvailable(.isUsingAppEnforcedTimeoutForMakingWalletConnectConnections) {
            infoLog("[WalletConnect] app-enforced timeout for waiting for new connection")
            analytics.log(action: Analytics.Action.walletConnectConnectionTimeout, properties: [
                Analytics.WalletConnectAction.connectionUrl.rawValue: url.absoluteString
            ])
            let errorMessage = R.string.localizable.walletConnectErrorConnectionTimeoutErrorMessage()
            displayConnectionTimeout(errorMessage)
        } else {
            infoLog("[WalletConnect] app-enforced timeout for waiting for new connection. Disabled")
        }
    }

    func provider(_ provider: WalletConnectProvider, shouldConnectFor proposal: AlphaWallet.WalletConnect.Proposal, completion: @escaping (AlphaWallet.WalletConnect.ProposalResponse) -> Void) {
        infoLog("[WalletConnect] shouldConnectFor connection: \(proposal)")
        let proposalType: ProposalType = .walletConnect(.init(proposal: proposal, config: config))
        firstly {
            AcceptProposalCoordinator.promise(navigationController, coordinator: self, proposalType: proposalType, analytics: analytics)
        }.done { choise in
            guard case .walletConnect(let server) = choise else {
                completion(.cancel)
                JumpBackToPreviousApp.goBackForWalletConnectSessionCancelled()
                return
            }
            completion(.connect(server))
            JumpBackToPreviousApp.goBackForWalletConnectSessionApproved()
        }.catch { _ in
            completion(.cancel)
        }.finally {
            self.resetSessionsToRemoveLoadingIfNeeded()
        }
    }
}

extension WalletConnectCoordinator: WalletConnectSessionsViewControllerDelegate {
    func startUniversalScanner() {
        delegate?.universalScannerSelected(in: self)
    }

    func qrCodeSelected(in viewController: WalletConnectSessionsViewController) {
        startUniversalScanner()
    }

    func didClose(in viewController: WalletConnectSessionsViewController) {
        infoLog("[WalletConnect] didClose")
        //NOTE: even if we haven't sessions view controller pushed to navigation stack, we need to make sure that root NavigationBar will be hidden
        navigationController.setNavigationBarHidden(true, animated: false)
    }

    func didDisconnectSelected(session: AlphaWallet.WalletConnect.Session, in viewController: WalletConnectSessionsViewController) {
        infoLog("[WalletConnect] didDisconnect session: \(session.topicOrUrl.description)")
        analytics.log(action: Analytics.Action.walletConnectDisconnect)
        do {
            try walletConnectProvider.disconnect(session.topicOrUrl)
        } catch {
            let errorMessage = R.string.localizable.walletConnectFailureTitle()
            displayErrorMessage(errorMessage)
        }
    }

    func didSessionSelected(session: AlphaWallet.WalletConnect.Session, in viewController: WalletConnectSessionsViewController) {
        infoLog("[WalletConnect] didSelect session: \(session)")
        guard let navigationController = viewController.navigationController else { return }

        display(session: session, in: navigationController)
    }
}

extension WalletConnectCoordinator: CanOpenURL {
    func didPressViewContractWebPage(forContract contract: AlphaWallet.Address, server: RPCServer, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(forContract: contract, server: server, in: viewController)
    }

    func didPressViewContractWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(url, in: viewController)
    }

    func didPressOpenWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressOpenWebPage(url, in: viewController)
    }
}
