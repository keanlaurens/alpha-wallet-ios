//
//  SessionsProvider.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 08.07.2022.
//

import Foundation
import Combine

public protocol SessionsProvider: AnyObject {
    var sessions: AnyPublisher<ServerDictionary<WalletSession>, Never> { get }
    var activeSessions: ServerDictionary<WalletSession> { get }

    func start()
    func session(for server: RPCServer) -> WalletSession?
}

open class BaseSessionsProvider: SessionsProvider {
    private let sessionsSubject: CurrentValueSubject<ServerDictionary<WalletSession>, Never> = .init(.init())
    private let config: Config
    private var cancelable = Set<AnyCancellable>()
    private let blockchainsProvider: BlockchainsProvider
    private let analytics: AnalyticsLogger
    private let tokensDataStore: TokensDataStore
    private let assetDefinitionStore: AssetDefinitionStore
    private let reachability: ReachabilityManagerProtocol
    private let wallet: Wallet
    private let eventsDataStore: NonActivityEventsDataStore

    public var sessions: AnyPublisher<ServerDictionary<WalletSession>, Never> {
        return sessionsSubject.eraseToAnyPublisher()
    }

    public var activeSessions: ServerDictionary<WalletSession> {
        sessionsSubject.value
    }

    public init(config: Config,
                analytics: AnalyticsLogger,
                blockchainsProvider: BlockchainsProvider,
                tokensDataStore: TokensDataStore,
                eventsDataStore: NonActivityEventsDataStore,
                assetDefinitionStore: AssetDefinitionStore,
                reachability: ReachabilityManagerProtocol,
                wallet: Wallet) {

        self.eventsDataStore = eventsDataStore
        self.wallet = wallet
        self.reachability = reachability
        self.assetDefinitionStore = assetDefinitionStore
        self.tokensDataStore = tokensDataStore
        self.config = config
        self.analytics = analytics
        self.blockchainsProvider = blockchainsProvider
    }

    public func start() {
        blockchainsProvider
            .blockchains
            .map { [weak self, sessionsSubject] blockchains -> ServerDictionary<WalletSession> in
                guard let strongSelf = self else { return .init() }
                var sessions: ServerDictionary<WalletSession> = .init()

                for blockchain in blockchains.values {
                    if let session = sessionsSubject.value[safe: blockchain.server] {
                        sessions[blockchain.server] = session
                    } else {
                        sessions[blockchain.server] = strongSelf.buildSession(blockchain: blockchain)
                    }
                }
                return sessions
            }.assign(to: \.value, on: sessionsSubject, ownership: .weak)
            .store(in: &cancelable)
    }

    private func buildSession(blockchain: BlockchainProvider) -> WalletSession {
        let ercTokenProvider: TokenProviderType = TokenProvider(
            account: wallet,
            blockchainProvider: blockchain)

        let contractDataFetcher = ContractDataFetcher(
            wallet: wallet,
            ercTokenProvider: ercTokenProvider,
            assetDefinitionStore: assetDefinitionStore,
            analytics: analytics,
            reachability: reachability)

        let importToken = ImportToken(
            tokensDataStore: tokensDataStore,
            contractDataFetcher: contractDataFetcher,
            server: blockchain.server,
            reachability: reachability)

        let nftProvider = AlphaWalletNFTProvider(
            analytics: analytics,
            wallet: wallet,
            server: blockchain.server,
            config: config,
            storage: .storage(for: wallet))

        let tokenAdaptor = TokenAdaptor(
            assetDefinitionStore: assetDefinitionStore,
            eventsDataStore: eventsDataStore,
            wallet: wallet,
            nftProvider: nftProvider)

        return WalletSession(
            account: wallet,
            server: blockchain.server,
            config: config,
            analytics: analytics,
            ercTokenProvider: ercTokenProvider,
            importToken: importToken,
            blockchainProvider: blockchain,
            nftProvider: nftProvider,
            tokenAdaptor: tokenAdaptor)
    }

    public func session(for server: RPCServer) -> WalletSession? {
        sessionsSubject.value[safe: server]
    }
}
