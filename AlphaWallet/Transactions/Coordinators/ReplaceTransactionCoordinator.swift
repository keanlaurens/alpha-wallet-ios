// Copyright © 2021 Stormbird PTE. LTD.

import UIKit
import BigInt
import AlphaWalletFoundation

protocol ReplaceTransactionCoordinatorDelegate: CanOpenURL, BuyCryptoDelegate {
    func didSendTransaction(_ transaction: SentTransaction, inCoordinator coordinator: ReplaceTransactionCoordinator)
    func didFinish(_ result: ConfirmResult, in coordinator: ReplaceTransactionCoordinator)
}

class ReplaceTransactionCoordinator: Coordinator {
    enum Mode {
        case speedup
        case cancel
    }

    private let tokensService: TokenViewModelState
    private let analytics: AnalyticsLogger
    private let domainResolutionService: DomainResolutionServiceType
    private let pendingTransactionInformation: (server: RPCServer, data: Data, transactionType: TransactionType, gasPrice: BigUInt)
    private let nonce: BigUInt
    private let keystore: Keystore
    private let presentingViewController: UIViewController
    private let session: WalletSession
    private let transaction: TransactionInstance
    private let mode: Mode
    private var transactionConfirmationResult: ConfirmResult? = .none
    private let assetDefinitionStore: AssetDefinitionStore
    private let networkService: NetworkService
    private var recipient: AlphaWallet.Address? {
        switch transactionType {
        case .nativeCryptocurrency:
            return AlphaWallet.Address(string: transaction.to)
        case .erc20Token, .erc875Token, .erc721Token, .erc721ForTicketToken, .erc1155Token, .prebuilt:
            return nil
        }
    }
    private var contract: AlphaWallet.Address? {
        switch transactionType {
        case .nativeCryptocurrency:
            return nil
        case .erc20Token, .erc875Token, .erc721Token, .erc721ForTicketToken, .erc1155Token, .prebuilt:
            return AlphaWallet.Address(string: transaction.to)
        }
    }
    private var transactionType: TransactionType {
        switch mode {
        case .speedup:
            return pendingTransactionInformation.transactionType
        case .cancel:
            //Cancel with a 0-value transfer transaction
            return .nativeCryptocurrency(MultipleChainsTokensDataStore.functional.etherToken(forServer: pendingTransactionInformation.server), destination: .address(session.account.address), amount: .notSet)
        }
    }
    private var transactionValue: BigUInt {
        switch mode {
        case .speedup:
            return BigUInt(transaction.value) ?? 0
        case .cancel:
            return 0
        }
    }
    private var transactionData: Data {
        switch mode {
        case .speedup:
            return pendingTransactionInformation.data
        case .cancel:
            return Data()
        }
    }
    private var transactionConfirmationConfiguration: TransactionType.Configuration {
        switch mode {
        case .speedup:
            return .speedupTransaction
        case .cancel:
            return .cancelTransaction
        }
    }

    var coordinators: [Coordinator] = []
    weak var delegate: ReplaceTransactionCoordinatorDelegate?

    init?(analytics: AnalyticsLogger,
          domainResolutionService: DomainResolutionServiceType,
          keystore: Keystore,
          presentingViewController: UIViewController,
          session: WalletSession,
          transaction: TransactionInstance,
          mode: Mode,
          assetDefinitionStore: AssetDefinitionStore,
          tokensService: TokenViewModelState,
          networkService: NetworkService) {
        guard let pendingTransactionInformation = TransactionDataStore.pendingTransactionsInformation[transaction.id] else { return nil }
        guard let nonce = BigUInt(transaction.nonce) else { return nil }
        self.networkService = networkService
        self.tokensService = tokensService
        self.pendingTransactionInformation = pendingTransactionInformation
        self.keystore = keystore
        self.analytics = analytics
        self.domainResolutionService = domainResolutionService
        self.presentingViewController = presentingViewController
        self.session = session
        self.transaction = transaction
        self.mode = mode
        self.nonce = nonce
        self.assetDefinitionStore = assetDefinitionStore
    }

    func start() {
        let unconfirmedTransaction = UnconfirmedTransaction(
            transactionType: transactionType,
            value: transactionValue,
            recipient: recipient,
            contract: contract,
            data: transactionData,
            gasPrice: computeGasPriceForReplacementTransaction(pendingTransactionInformation.gasPrice),
            nonce: nonce)

        let coordinator = TransactionConfirmationCoordinator(
            presentingViewController: presentingViewController,
            session: session,
            transaction: unconfirmedTransaction,
            configuration: transactionConfirmationConfiguration,
            analytics: analytics,
            domainResolutionService: domainResolutionService,
            keystore: keystore,
            assetDefinitionStore: assetDefinitionStore,
            tokensService: tokensService,
            networkService: networkService)
        
        coordinator.delegate = self
        addCoordinator(coordinator)

        switch mode {
        case .speedup:
            coordinator.start(fromSource: .speedupTransaction)
        case .cancel:
            coordinator.start(fromSource: .cancelTransaction)
        }
    }

    private func computeGasPriceForReplacementTransaction(_ gasPrice: BigUInt) -> BigUInt {
        gasPrice * 110 / 100
    }
}

extension ReplaceTransactionCoordinator: TransactionConfirmationCoordinatorDelegate {
    func coordinator(_ coordinator: TransactionConfirmationCoordinator, didFailTransaction error: Error) {
        UIApplication.shared
            .presentedViewController(or: presentingViewController)
            .displayError(message: error.prettyError)
    }

    func didSendTransaction(_ transaction: SentTransaction, inCoordinator coordinator: TransactionConfirmationCoordinator) {
        delegate?.didSendTransaction(transaction, inCoordinator: self)
    }

    func didFinish(_ result: ConfirmResult, in coordinator: TransactionConfirmationCoordinator) {
        coordinator.close { [weak self] in
            guard let strongSelf = self else { return }

            strongSelf.removeCoordinator(coordinator)
            strongSelf.transactionConfirmationResult = result

            let coordinator = TransactionInProgressCoordinator(presentingViewController: strongSelf.presentingViewController)
            coordinator.delegate = strongSelf
            strongSelf.addCoordinator(coordinator)

            coordinator.start()
        }
    }

    func didClose(in coordinator: TransactionConfirmationCoordinator) {
        removeCoordinator(coordinator)
    }

    func buyCrypto(wallet: Wallet, server: RPCServer, viewController: UIViewController, source: Analytics.BuyCryptoSource) {
        let source: Analytics.BuyCryptoSource
        switch mode {
        case .speedup:
            source = .speedupTransactionInsufficientFunds
        case .cancel:
            source = .cancelTransactionInsufficientFunds
        }
        delegate?.buyCrypto(wallet: wallet, server: server, viewController: viewController, source: source)
    }
}

extension ReplaceTransactionCoordinator: TransactionInProgressCoordinatorDelegate {

    func didDismiss(in coordinator: TransactionInProgressCoordinator) {
        removeCoordinator(coordinator)

        switch transactionConfirmationResult {
        case .some(let result):
            delegate?.didFinish(result, in: self)
        case .none:
            break
        }
    }
}

extension ReplaceTransactionCoordinator: CanOpenURL {
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
