//
//  RecipientResolver.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 20.08.2020.
//

import Foundation
import Combine
import CombineExt

public struct RecipientViewModel {
    public var address: AlphaWallet.Address?
    public var ensName: String?
}

public class RecipientResolver {
    public enum Row: Int, CaseIterable {
        case address
        case ens
    }

    public let address: AlphaWallet.Address?
    private var resolution: Loadable<BlockieAndAddressOrEnsResolution, Error> = .loading
    public var ensName: EnsName? {
        resolution.value?.resolution.value
    }
    public var blockieImage: BlockiesImage? {
        resolution.value?.image
    }

    public var hasResolvedEnsName: Bool {
        if let value = resolution.value?.resolution.value {
            return !value.trimmed.isEmpty
        }
        return false
    }
    private let domainResolutionService: DomainResolutionServiceType

    public init(address: AlphaWallet.Address?, domainResolutionService: DomainResolutionServiceType) {
        self.address = address
        self.domainResolutionService = domainResolutionService
    }

    private struct RecipientResolutionError: Error {
        let message: String
    }

    public func resolveRecipient() -> AnyPublisher<Loadable<BlockieAndAddressOrEnsResolution, Error>, Never> {
        guard let address = address else {
            return .just(.failure(RecipientResolutionError(message: "address not found")))
                .prepend(.loading)
                .eraseToAnyPublisher()
        }

        return domainResolutionService.resolveEnsAndBlockie(address: address)
            .map { resolution -> Loadable<BlockieAndAddressOrEnsResolution, Error> in return .done(resolution) }
            .catch { return Just(Loadable<BlockieAndAddressOrEnsResolution, Error>.failure($0)) }
            .handleEvents(receiveOutput: { [weak self] in self?.resolution = $0 })
            .prepend(.loading)
            .eraseToAnyPublisher()
    }

    public var value: String? {
        return address?.eip55String
    }
}
