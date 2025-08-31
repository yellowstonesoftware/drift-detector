//
//  Argo+RolloutCondition.swift
//  DriftDetector
//
//  Created by Peter van Rensburg on 8/29/25.
//

import Foundation
import SwiftkubeModel

extension argoproj.v1alpha1 {

  public struct RolloutCondition: KubernetesResource {
    public var lastTransitionTime: Date?
    public var lastUpdateTime: Date?
    public var message: String?
    public var reason: String?
    public var status: String
    public var type: String
    public init(
      lastTransitionTime: Date? = nil,
      lastUpdateTime: Date? = nil,
      message: String? = nil,
      reason: String? = nil,
      status: String,
      type: String
    ) {
      self.lastTransitionTime = lastTransitionTime
      self.lastUpdateTime = lastUpdateTime
      self.message = message
      self.reason = reason
      self.status = status
      self.type = type
    }
  }
}

extension argoproj.v1alpha1.RolloutCondition {

  private enum CodingKeys: String, CodingKey {

    case lastTransitionTime = "lastTransitionTime"
    case lastUpdateTime = "lastUpdateTime"
    case message = "message"
    case reason = "reason"
    case status = "status"
    case type = "type"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.lastTransitionTime = try container.decodeIfPresent(Date.self, forKey: .lastTransitionTime)
    self.lastUpdateTime = try container.decodeIfPresent(Date.self, forKey: .lastUpdateTime)
    self.message = try container.decodeIfPresent(String.self, forKey: .message)
    self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
    self.status = try container.decode(String.self, forKey: .status)
    self.type = try container.decode(String.self, forKey: .type)
  }

  public func encode(to encoder: Encoder) throws {
    var encodingContainer = encoder.container(keyedBy: CodingKeys.self)

    try encodingContainer.encode(lastTransitionTime, forKey: .lastTransitionTime)
    try encodingContainer.encode(lastUpdateTime, forKey: .lastUpdateTime)
    try encodingContainer.encode(message, forKey: .message)
    try encodingContainer.encode(reason, forKey: .reason)
    try encodingContainer.encode(status, forKey: .status)
    try encodingContainer.encode(type, forKey: .type)
  }
}
