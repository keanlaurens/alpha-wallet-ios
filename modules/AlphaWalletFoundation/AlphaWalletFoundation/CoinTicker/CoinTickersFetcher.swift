//
//  CoinTickersFetcher.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 27.01.2021.
//

import Combine
import Foundation

public protocol CoinTickersFetcher: AnyObject, CoinTickersFetcherProvider {
    var tickersDidUpdate: AnyPublisher<Void, Never> { get }
    var updateTickerIds: AnyPublisher<[(tickerId: TickerIdString, key: AddressAndRPCServer)], Never> { get }

    func ticker(for key: AddressAndRPCServer, currency: Currency) -> CoinTicker?
    func addOrUpdateTestsOnly(ticker: CoinTicker?, for token: TokenMappedToTicker)
}

public struct AssignedCoinTickerId: Hashable, Codable {
    /// Represents ticker id for all available chains
    public let tickerId: TickerIdString
    /// Primary token for each ticker id found
    public let primaryToken: AddressAndRPCServer
}

extension AssignedCoinTickerId {
    init(tickerId: TickerIdString, token: TokenMappedToTicker) {
        self.tickerId = tickerId
        self.primaryToken = .init(address: token.contractAddress, server: token.server)
    }
}

extension AssignedCoinTickerId: Equatable {
    /// Checks for matching primary token matching or some of platforms is the same
    public static func == (lhs: AssignedCoinTickerId, rhs: AddressAndRPCServer) -> Bool {
        return lhs.primaryToken == rhs
    }

    /// Checks for matching of ticker id
    public static func == (lhs: AssignedCoinTickerId, rhs: TickerIdString) -> Bool {
        return lhs.tickerId == rhs
    }
}
