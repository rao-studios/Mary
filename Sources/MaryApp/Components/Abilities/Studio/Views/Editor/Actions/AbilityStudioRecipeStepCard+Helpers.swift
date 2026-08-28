//
//  AbilityStudioRecipeStepCard+Helpers.swift
//

import MaryBrain
import SwiftUI

extension AbilityStudioRecipeStepCard {

    func scalar(
        _ label: String,
        expression: PluginScalarExpression,
        onChange: @escaping (PluginScalarExpression) -> Void
    ) -> some View {
        AbilityStudioScalarExpressionEditor(
            label: label,
            path: "\(stepPath).rect.\(label)",
            expression: expression,
            inputNames: coordinateInputNames(
                positive: label == "width" || label == "height"),
            onChange: onChange)
    }

    func mutateRect(_ change: (inout PluginRectExpression) -> Void) {
        mutateStep { target in
            var rect = target.rect ?? .init(
                x: .init(value: 0.3), y: .init(value: 0.3),
                width: .init(value: 0.2), height: .init(value: 0.2))
            change(&rect)
            target.rect = rect
        }
    }

    func mutateStep(_ change: (inout PluginRecipeStepSchema) -> Void) {
        switch owner {
        case .callable:
            model.mutateAuthoringDocument {
                try $0.updateStep(
                    step.id,
                    in: operation.operation,
                    lane: lane,
                    change)
            }
        }
    }

    func move(_ offset: Int) {
        let target = stepIndex + offset
        guard laneSteps.indices.contains(target) else { return }
        switch owner {
        case .callable:
            model.mutateAuthoringDocument {
                try $0.moveStep(
                    step.id,
                    in: operation.operation,
                    to: target,
                    lane: lane)
            }
        }
    }

    func remove() {
        switch owner {
        case .callable:
            model.mutateAuthoringDocument {
                try $0.removeStep(
                    step.id,
                    from: operation.operation,
                    lane: lane)
            }
        }
    }

}
