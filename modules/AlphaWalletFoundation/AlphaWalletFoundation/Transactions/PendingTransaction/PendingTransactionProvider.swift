//
//  PendingTransactionProvider.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 01.04.2022.
//

import Foundation
import BigInt
import Combine

final class PendingTransactionProvider {
    private let session: WalletSession
    private let transactionDataStore: TransactionDataStore
    private let ercTokenDetector: ErcTokenDetector
    private var cancelable = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.PendingTransactionProvider.updateQueue")
    private let fetchPendingTransactionsQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Auto-update Pending Transactions"
        queue.maxConcurrentOperationCount = 5

        return queue
    }()

    private var store: [String: SchedulerProtocol] = [:]

    init(session: WalletSession, transactionDataStore: TransactionDataStore, ercTokenDetector: ErcTokenDetector) {
        self.session = session
        self.transactionDataStore = transactionDataStore
        self.ercTokenDetector = ercTokenDetector
    }

    func start() {
        transactionDataStore
            .initialOrNewTransactionsPublisher(forServer: session.server, transactionState: .pending)
            .receive(on: queue)
            .sink { [weak self] transactions in self?.runPendingTransactionWatchers(transactions: transactions) }
            .store(in: &cancelable)
    }

    func cancelScheduler() {
        queue.async {
            for each in self.store {
                each.value.cancel()
            }
        }
    }

    func resumeScheduler() {
        queue.async {
            for each in self.store {
                each.value.resume()
            }
        }
    }

    deinit {
        for each in self.store {
            each.value.cancel()
        }
    }

    private func runPendingTransactionWatchers(transactions: [TransactionInstance]) {
        for each in transactions {
            guard store[each.id] == nil else { continue }

            let provider = PendingTransactionSchedulerProvider(
                blockchainProvider: session.blockchainProvider,
                transaction: each,
                fetchPendingTransactionsQueue: fetchPendingTransactionsQueue)

            provider.responsePublisher
                .receive(on: queue)
                .sink { [weak self] in self?.handle(response: $0, for: provider) }
                .store(in: &cancelable)

            let scheduler = Scheduler(provider: provider)
            scheduler.start()

            store[each.id] = scheduler
        }
    }

    private func handle(response: Result<EthereumTransaction, SessionTaskError>, for provider: PendingTransactionSchedulerProvider) {
        switch response {
        case .success(let pendingTransaction):
            didReceiveValue(transaction: provider.transaction, pendingTransaction: pendingTransaction)
        case .failure(let error):
            didReceiveError(error: error, forTransaction: provider.transaction)
        }
    }

    private func didReceiveValue(transaction: TransactionInstance, pendingTransaction: EthereumTransaction) {
        transactionDataStore.update(state: .completed, for: transaction.primaryKey, withPendingTransaction: pendingTransaction)
        ercTokenDetector.detect(from: [transaction])

        cancelScheduler(transaction: transaction)
    }

    private func cancelScheduler(transaction: TransactionInstance) {
        guard let scheduler = store[transaction.id] else { return }
        scheduler.cancel()
        store[transaction.id] = nil
    }

    private func didReceiveError(error: SessionTaskError, forTransaction transaction: TransactionInstance) {
        switch error {
        case .responseError(let error):
            // TODO: Think about the logic to handle pending transactions.
            //TODO we need to detect when a transaction is marked as failed by the node?
            switch error as? JSONRPCError {
            case .responseError:
                transactionDataStore.delete(transactions: [transaction])
                cancelScheduler(transaction: transaction)
            case .resultObjectParseError:
                guard transactionDataStore.hasCompletedTransaction(withNonce: transaction.nonce, forServer: session.server) else { return }
                transactionDataStore.delete(transactions: [transaction])
                cancelScheduler(transaction: transaction)
                //The transaction might not be posted to this node yet (ie. it doesn't even think that this transaction is pending). Especially common if we post a transaction to Ethermine and fetch pending status through Etherscan
            case .responseNotFound, .errorObjectParseError, .unsupportedVersion, .unexpectedTypeObject, .missingBothResultAndError, .nonArrayResponse, .none:
                break
            }
        case .connectionError, .requestError:
            break
        }
    }
}

extension TransactionDataStore {
    func initialOrNewTransactionsPublisher(forServer server: RPCServer, transactionState: TransactionState) -> AnyPublisher<[TransactionInstance], Never> {
        let predicate = TransactionDataStore.functional.transactionPredicate(server: server, transactionState: .pending)
        return transactionsChangeset(filter: .predicate(predicate), servers: [server])
            .map { changeset in
                switch changeset {
                case .initial(let transactions): return transactions
                case .update(let transactions, _, let insertions, _): return insertions.map { transactions[$0] }
                case .error: return []
                }
            }.filter { !$0.isEmpty }
            .eraseToAnyPublisher()
    }
}
