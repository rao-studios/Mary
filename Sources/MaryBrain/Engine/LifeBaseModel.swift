//
//  LifeBaseModel.swift
//  MaryBrain
//
//  WHAT: The base model a Life adapter is trained on and answers through.
//  IN:   LifeTrainer (what Fleet trains against), the remote session's guard
//  PIN:  Was MaryLocalEngine.defaultModelID, which Mary no longer loads. The
//        id still matters: an adapter knows which base it learned on, and
//        Fleet refuses a mismatch rather than producing confident nonsense.
//
import Foundation

public enum LifeBaseModel {
    public static let defaultModelID = "mlx-community/Mistral-Nemo-Instruct-2407-4bit"
}
