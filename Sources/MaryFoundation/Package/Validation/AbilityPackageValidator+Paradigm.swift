//
//  AbilityPackageValidator+Paradigm.swift
//  MaryFoundation
//
//  WHAT: Declared AbilityParadigm must match package shape.
//  IN:   AbilityPackageValidator.validate.
//  OUT:  PackageIssueSink. Roles: AbilityParadigm.swift.
//

import Foundation

extension AbilityPackageValidator {
    static func validateParadigm(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        // PIN: `.systemControl` is not recoverable from structure — check the declaration.
        if let declared = package.ability.paradigm {
            let path = "\(package.package.id).ability.paradigm"
            switch declared {
            case .applicationExpertise:
                // Expertise names an application.
                if package.applicationAffinities.allSatisfy({ $0.bundleIdentifiers.isEmpty }) {
                    sink.error(
                        "paradigm-expertise-without-application", path,
                        "An application-expertise Ability must name the application it knows — carry a Plugin bound to a bundle identifier, or declare ability.applications.")
                }
                // Extends a craft. Warning only — self-contained app Ability is unusual, not illegal.
                if package.extendedDisciplines.isEmpty {
                    sink.warning(
                        "paradigm-expertise-without-discipline", path,
                        "An application-expertise Ability usually extends a discipline; depend on that discipline package so the two compose.")
                }
            case .systemControl:
                // Role is not about one app.
                if let named = package.applicationAffinities.first(where: {
                    !$0.bundleIdentifiers.isEmpty
                }) {
                    sink.error(
                        "paradigm-system-bound-to-application", path,
                        "A computer-control Ability must not bind itself to one application; this one names \(named.title). Declare it as application expertise instead.")
                }
            case .reasoning:
                if let bound = package.skills.first(where: { $0.execution.kind == .binding }) {
                    sink.error(
                        "paradigm-reasoning-with-hands", path,
                        "A reasoning Ability has no hands, but Skill \(bound.id.rawValue) binds an adapter operation.")
                }
            case .discipline:
                // Discipline + application plugin is expertise wearing a craft name.
                if package.plugin != nil {
                    sink.error(
                        "paradigm-discipline-with-plugin", path,
                        "A discipline describes portable craft, but this package carries a Plugin bound to an application. Declare it as application expertise.")
                }
            }
        }
    }
}
