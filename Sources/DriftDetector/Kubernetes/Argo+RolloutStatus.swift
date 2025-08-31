//
//  Argo+RolloutStatus.swift
//  DriftDetector
//
//  Created by Peter van Rensburg on 8/29/25.
//

import Foundation
import SwiftkubeModel

// MARK: - argoproj.v1alpha1.RolloutStatus

extension argoproj.v1alpha1 {

  public struct RolloutStatus: KubernetesResource {
    public var availableReplicas: Int32?
    public var conditions: [argoproj.v1alpha1.RolloutCondition]?
    public var observedGeneration: String?
    public var readyReplicas: Int32?
    public var replicas: Int32?
    public init(
      availableReplicas: Int32? = nil,
      conditions: [argoproj.v1alpha1.RolloutCondition]? = nil,
      observedGeneration: String? = nil,
      readyReplicas: Int32? = nil,
      replicas: Int32? = nil,
    ) {
      self.availableReplicas = availableReplicas
      self.conditions = conditions
      self.observedGeneration = observedGeneration
      self.readyReplicas = readyReplicas
      self.replicas = replicas
    }
  }
}

extension argoproj.v1alpha1.RolloutStatus {

  private enum CodingKeys: String, CodingKey {
    case availableReplicas = "availableReplicas"
    case conditions = "conditions"
    case observedGeneration = "observedGeneration"
    case readyReplicas = "readyReplicas"
    case replicas = "replicas"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.availableReplicas = try container.decodeIfPresent(Int32.self, forKey: .availableReplicas)
    self.conditions = try container.decodeIfPresent([argoproj.v1alpha1.RolloutCondition].self, forKey: .conditions)
    self.observedGeneration = try container.decodeIfPresent(String.self, forKey: .observedGeneration)
    self.readyReplicas = try container.decodeIfPresent(Int32.self, forKey: .readyReplicas)
    self.replicas = try container.decodeIfPresent(Int32.self, forKey: .replicas)
  }

  public func encode(to encoder: Encoder) throws {
    var encodingContainer = encoder.container(keyedBy: CodingKeys.self)

    try encodingContainer.encode(availableReplicas, forKey: .availableReplicas)
    try encodingContainer.encode(conditions, forKey: .conditions)
    try encodingContainer.encode(observedGeneration, forKey: .observedGeneration)
    try encodingContainer.encode(readyReplicas, forKey: .readyReplicas)
    try encodingContainer.encode(replicas, forKey: .replicas)
  }
}
