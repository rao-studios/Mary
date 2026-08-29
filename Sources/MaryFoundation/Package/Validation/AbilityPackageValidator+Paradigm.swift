//
//  AbilityPackageValidator+Paradigm.swift
//  MaryFoundation
//
//  A DECLARED PARADIGM MUST MATCH THE PACKAGE'S SHAPE. See AbilityParadigm.swift
//  for what each role means; this is where a role that nobody checks stops
//  being a comfortable lie.
//

import Foundation

extension AbilityPackageValidator {
    static func validateParadigm(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        // A DECLARED PARADIGM MUST MATCH THE PACKAGE'S SHAPE. The field is
        // declared rather than derived because "controls the computer" is not
        // recoverable from structure — but a declaration nobody checks is a
        // comfortable lie waiting to happen, so each role states what it
        // implies and the structure has to agree.
        if let declared = package.ability.paradigm {
            let path = "\(package.package.id).ability.paradigm"
            switch declared {
            case .applicationExpertise:
                // Expertise is expertise IN something.
                if package.applicationAffinities.allSatisfy({ $0.bundleIdentifiers.isEmpty }) {
                    sink.error(
                        "paradigm-expertise-without-application", path,
                        "An application-expertise Ability must name the application it knows — carry a Plugin bound to a bundle identifier, or declare ability.applications.")
                }
                // …and it extends a craft rather than replacing it. A warning,
                // not an error: a self-contained application Ability with no
                // portable discipline behind it is unusual, not illegal.
                if package.extendedDisciplines.isEmpty {
                    sink.warning(
                        "paradigm-expertise-without-discipline", path,
                        "An application-expertise Ability usually extends a discipline; depend on that discipline package so the two compose.")
                }
            case .systemControl:
                // The whole point of the role is that it is not about one app.
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
                // A craft that carries its own application plugin is really
                // expertise in that application wearing a discipline's name.
                if package.plugin != nil {
                    sink.error(
                        "paradigm-discipline-with-plugin", path,
                        "A discipline describes portable craft, but this package carries a Plugin bound to an application. Declare it as application expertise.")
                }
            }
        }
    }
}
