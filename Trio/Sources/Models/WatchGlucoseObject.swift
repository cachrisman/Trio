//
//  WatchGlucoseObject.swift
//  Trio
//
//  Created by Cengiz Deniz on 23.01.25.
//
import Foundation

struct WatchGlucoseObject: Hashable, Equatable, Codable {
    let date: Date
    /// Canonical mg/dL (build 205 / P2). The watch converts to display units and computes color locally.
    let glucose: Double
}
