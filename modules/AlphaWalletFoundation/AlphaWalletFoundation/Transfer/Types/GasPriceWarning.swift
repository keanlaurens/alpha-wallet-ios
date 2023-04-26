//
//  GasPriceWarning.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 10.05.2022.
//

import Foundation

extension TransactionConfigurator {
    public enum GasPriceWarning: Warning {
        case tooHighCustomGasPrice
        case networkCongested
        case tooLowCustomGasPrice
    }
}
