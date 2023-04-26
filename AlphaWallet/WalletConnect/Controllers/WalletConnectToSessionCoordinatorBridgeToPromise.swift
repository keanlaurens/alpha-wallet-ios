//
//  AcceptProposalCoordinatorBridgeToPromise.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 18.02.2021.
//

import PromiseKit
import AlphaWalletFoundation

private class AcceptProposalCoordinatorBridgeToPromise {

    private let (promiseToReturn, seal) = Promise<ProposalResult>.pending()
    private var retainCycle: AcceptProposalCoordinatorBridgeToPromise?

    init(navigationController: UINavigationController,
         coordinator: Coordinator,
         proposalType: ProposalType,
         analytics: AnalyticsLogger,
         config: Config,
         restartHandler: RestartQueueHandler,
         networkService: NetworkService,
         serversProvider: ServersProvidable) {

        retainCycle = self

        let newCoordinator = AcceptProposalCoordinator(
            analytics: analytics,
            proposalType: proposalType,
            navigationController: navigationController,
            config: config,
            restartHandler: restartHandler,
            networkService: networkService,
            serversProvider: serversProvider)

        newCoordinator.delegate = self
        coordinator.addCoordinator(newCoordinator)

        promiseToReturn.ensure {
            // ensure we break the retain cycle
            self.retainCycle = nil
            coordinator.removeCoordinator(newCoordinator)
        }.cauterize()

        newCoordinator.start()
    }

    var promise: Promise<ProposalResult> {
        return promiseToReturn
    }
}

extension AcceptProposalCoordinatorBridgeToPromise: AcceptProposalCoordinatorDelegate {
    func coordinator(_ coordinator: AcceptProposalCoordinator, didComplete result: ProposalResult) {
        seal.fulfill(result)
    }
}

extension AcceptProposalCoordinator {

    static func promise(_ navigationController: UINavigationController,
                        coordinator: Coordinator,
                        proposalType: ProposalType,
                        analytics: AnalyticsLogger,
                        config: Config,
                        restartHandler: RestartQueueHandler,
                        networkService: NetworkService,
                        serversProvider: ServersProvidable) -> Promise<ProposalResult> {

        return AcceptProposalCoordinatorBridgeToPromise(
            navigationController: navigationController,
            coordinator: coordinator,
            proposalType: proposalType,
            analytics: analytics,
            config: config,
            restartHandler: restartHandler,
            networkService: networkService,
            serversProvider: serversProvider).promise
    }
}
