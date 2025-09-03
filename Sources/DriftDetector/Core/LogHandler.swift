//
//  LogHandler.swift
//  DriftDetector
//
//  Created by Peter van Rensburg on 9/1/25.
//

import Logging
import Foundation

public enum LoggingKit {
  public static func bootstrap(
      level: Logger.Level,
      metadataProvider: Logger.MetadataProvider? = .none) {
    LoggingSystem.bootstrap { label in
      var h = StreamLogHandler.standardOutput(label: label)
      h.logLevel = level
      h.metadataProvider = metadataProvider
      return h
    }
  }

  @inlinable
  public static func logger(
      category: String? = nil,
      base: String = "io.ys.driftdetector",
      fileID: String = #fileID) -> Logger {
    let derived = fileID
          .replacingOccurrences(of: ".swift", with: "")
          .replacingOccurrences(of: "/", with: ".")
    return Logger(label: [base, category ?? derived].joined(separator: "."))
  }
}
