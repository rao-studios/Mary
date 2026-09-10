//
//  MaryComputerUseExports.swift
//  MaryPlugin
//
//  WHAT: Re-export the machine layer.
//  OUT:  MaryComputerUse
//  PIN:  A consumer naming AXEngine or KeyChordPress need not know the machine
//        layer became its own target. The edge is one-way — MaryComputerUse
//        never imports MaryPlugin, and a test pins that it cannot.
//
@_exported import MaryComputerUse
